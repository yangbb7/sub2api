#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/deploy-1g.env.local}"
READY_SCRIPT="${VERIFY_READY_SCRIPT:-${DEPLOY_DIR}/ready-1g.sh}"
DNS_SCRIPT="${VERIFY_DNS_SCRIPT:-${DEPLOY_DIR}/cloudflare-upsert-dns.sh}"
CHECK_SCRIPT="${VERIFY_CHECK_SCRIPT:-${DEPLOY_DIR}/check-1g.sh}"
LIVE_REPORT_FILE="${LIVE_REPORT_FILE:-}"

CLI_TARGET_REGION_SET=false
CLI_DOMAIN_SET=false
CLI_TARGET_IP_SET=false
CLI_PROXIED_SET=false
CLI_CF_API_TOKEN_SET=false
CLI_CF_ZONE_ID_SET=false
[ "${TARGET_REGION+x}" = x ] && CLI_TARGET_REGION_SET=true
[ "${DOMAIN+x}" = x ] && CLI_DOMAIN_SET=true
[ "${TARGET_IP+x}" = x ] && CLI_TARGET_IP_SET=true
[ "${PROXIED+x}" = x ] && CLI_PROXIED_SET=true
[ "${CF_API_TOKEN+x}" = x ] && CLI_CF_API_TOKEN_SET=true
[ "${CF_ZONE_ID+x}" = x ] && CLI_CF_ZONE_ID_SET=true

load_env_file() {
  local env_file="$1"
  local restore_commands=""
  local name
  for name in \
    TARGET_REGION DOMAIN TARGET_IP PROXIED CF_API_TOKEN CF_ZONE_ID \
    JP_TARGET_IP HK_TARGET_IP
  do
    if [ "${!name+x}" = x ]; then
      restore_commands+="$(printf 'export %s=%q;' "${name}" "${!name}")"
    fi
  done
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
  eval "${restore_commands}"
}

if [ ! -f "${ENV_FILE}" ]; then
  echo "ENV_FILE does not exist: ${ENV_FILE}" >&2
  exit 1
fi
load_env_file "${ENV_FILE}"

TARGET_REGION="${TARGET_REGION:-}"
DOMAIN="${DOMAIN:-}"
TARGET_IP="${TARGET_IP:-}"
PROXIED="${PROXIED:-false}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
JP_TARGET_IP="${JP_TARGET_IP:-}"
HK_TARGET_IP="${HK_TARGET_IP:-}"

if [ "${CLI_TARGET_REGION_SET}" = true ]; then TARGET_REGION="${TARGET_REGION}"; fi
if [ "${CLI_DOMAIN_SET}" = true ]; then DOMAIN="${DOMAIN}"; fi
if [ "${CLI_TARGET_IP_SET}" = true ]; then TARGET_IP="${TARGET_IP}"; fi
if [ "${CLI_PROXIED_SET}" = true ]; then PROXIED="${PROXIED}"; fi
if [ "${CLI_CF_API_TOKEN_SET}" = true ]; then CF_API_TOKEN="${CF_API_TOKEN}"; fi
if [ "${CLI_CF_ZONE_ID_SET}" = true ]; then CF_ZONE_ID="${CF_ZONE_ID}"; fi

if [ -z "${DOMAIN}" ]; then
  echo "DOMAIN is required" >&2
  exit 1
fi
if [ -z "${CF_API_TOKEN}" ]; then
  echo "CF_API_TOKEN is required" >&2
  exit 1
fi

candidate_target_ips() {
  if [ -n "${TARGET_IP}" ]; then
    printf '%s\n' "${TARGET_IP}"
    return
  fi
  case "${TARGET_REGION}" in
    jp|japan)
      [ -n "${JP_TARGET_IP}" ] && printf '%s\n' "${JP_TARGET_IP}"
      ;;
    hk|hongkong)
      [ -n "${HK_TARGET_IP}" ] && printf '%s\n' "${HK_TARGET_IP}"
      ;;
    auto|"")
      [ -n "${JP_TARGET_IP}" ] && printf '%s\n' "${JP_TARGET_IP}"
      [ -n "${HK_TARGET_IP}" ] && printf '%s\n' "${HK_TARGET_IP}"
      ;;
    *)
      echo "TARGET_REGION must be auto, jp, hk, or empty" >&2
      exit 1
      ;;
  esac
}

echo "Checking local readiness..."
ENV_FILE="${ENV_FILE}" "${READY_SCRIPT}"

echo "Checking Cloudflare DNS A record..."
matched_ip=""
while IFS= read -r candidate_ip; do
  [ -z "${candidate_ip}" ] && continue
  if CF_API_TOKEN="${CF_API_TOKEN}" CF_ZONE_ID="${CF_ZONE_ID}" DOMAIN="${DOMAIN}" TARGET_IP="${candidate_ip}" PROXIED="${PROXIED}" CHECK_ONLY=true \
    "${DNS_SCRIPT}" >/dev/null 2>&1; then
    matched_ip="${candidate_ip}"
    break
  fi
done <<EOF
$(candidate_target_ips)
EOF

if [ -z "${matched_ip}" ]; then
  echo "Cloudflare DNS A record does not match any configured target IP for ${DOMAIN}" >&2
  exit 1
fi
echo "Cloudflare DNS verified: ${DOMAIN} -> ${matched_ip} (proxied=${PROXIED})"

echo "Checking remote services and HTTPS frontend..."
TARGET_IP="${matched_ip}" ENV_FILE="${ENV_FILE}" "${CHECK_SCRIPT}"

if [ -n "${LIVE_REPORT_FILE}" ]; then
  mkdir -p "$(dirname "${LIVE_REPORT_FILE}")"
  DOMAIN="${DOMAIN}" TARGET_IP="${matched_ip}" PROXIED="${PROXIED}" ENV_FILE="${ENV_FILE}" LIVE_REPORT_FILE="${LIVE_REPORT_FILE}" python3 - <<'PY'
import json
import os
from datetime import datetime, timezone

report = {
    "verified_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "domain": os.environ["DOMAIN"],
    "target_ip": os.environ["TARGET_IP"],
    "proxied": os.environ["PROXIED"].lower() == "true",
    "env_file": os.environ["ENV_FILE"],
    "checks": [
        "local_readiness",
        "cloudflare_a_record_target",
        "cloudflare_proxied_state",
        "remote_compose_and_localhost",
        "https_health_login_and_frontend_asset",
    ],
}
with open(os.environ["LIVE_REPORT_FILE"], "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
  chmod 600 "${LIVE_REPORT_FILE}"
  echo "Wrote live verification report: ${LIVE_REPORT_FILE}"
fi

echo "1G live verification passed: ${DOMAIN} is deployed on ${matched_ip}"
