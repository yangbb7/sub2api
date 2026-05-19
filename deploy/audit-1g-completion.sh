#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/deploy-1g.env.local}"
LIVE_REPORT_FILE="${LIVE_REPORT_FILE:-${DEPLOY_DIR}/live-1g-report.json}"
VERIFY_SCRIPT="${AUDIT_VERIFY_SCRIPT:-${DEPLOY_DIR}/verify-live-1g.sh}"
RUN_VERIFY="${RUN_VERIFY:-false}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "OK: $*"
}

file_mode() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null || true
}

require_restrictive_mode() {
  local path="$1"
  local label="$2"
  local mode
  mode="$(file_mode "${path}")"
  case "${mode}" in
    600|400) ok "${label} permissions are restrictive: ${mode}" ;;
    *) fail "${label} permissions are too open: ${mode:-unknown}; run chmod 600 ${path}" ;;
  esac
}

reject_persisted_secret() {
  local name="$1"
  if awk -F= -v key="${name}" '
    $0 !~ /^[[:space:]]*#/ && $1 == key {
      sub(/^[^=]*=/, "")
      if (length($0) > 0) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "${ENV_FILE}"; then
    fail "${ENV_FILE} contains ${name}; export secrets in the shell instead"
  fi
}

case "${RUN_VERIFY}" in
  true|false) ;;
  *) fail "RUN_VERIFY must be true or false" ;;
esac

if [ "${RUN_VERIFY}" = true ]; then
  LIVE_REPORT_FILE="${LIVE_REPORT_FILE}" ENV_FILE="${ENV_FILE}" "${VERIFY_SCRIPT}"
fi

if [ ! -f "${ENV_FILE}" ]; then
  fail "ENV_FILE does not exist: ${ENV_FILE}"
fi
require_restrictive_mode "${ENV_FILE}" "env file"

reject_persisted_secret SSH_PASS
reject_persisted_secret SSH_PASSWORD
reject_persisted_secret JP_SSH_PASS
reject_persisted_secret JP_SSH_PASSWORD
reject_persisted_secret HK_SSH_PASS
reject_persisted_secret HK_SSH_PASSWORD
reject_persisted_secret SUDO_PASSWORD
reject_persisted_secret CF_API_TOKEN
ok "secrets are not persisted in ${ENV_FILE}"

if [ ! -f "${LIVE_REPORT_FILE}" ]; then
  fail "missing live verification report: ${LIVE_REPORT_FILE}; run RUN_VERIFY=true ENV_FILE=${ENV_FILE} ${0}"
fi
require_restrictive_mode "${LIVE_REPORT_FILE}" "live verification report"

python3 - "${LIVE_REPORT_FILE}" "${ENV_FILE}" <<'PY'
import ipaddress
import json
import sys
from datetime import datetime

report_path, env_path = sys.argv[1:3]
required_checks = {
    "local_readiness",
    "cloudflare_a_record_target",
    "cloudflare_proxied_state",
    "remote_compose_and_localhost",
    "https_health_login_and_frontend_asset",
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_env(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                value = value[1:-1]
            values[key] = value
    return values


try:
    with open(report_path, encoding="utf-8") as fh:
        report = json.load(fh)
except Exception as exc:
    fail(f"live verification report is not valid JSON: {exc}")

if not isinstance(report, dict):
    fail("live verification report must be a JSON object")

env = parse_env(env_path)
domain = report.get("domain")
target_ip = report.get("target_ip")
proxied = report.get("proxied")
verified_at = report.get("verified_at_utc")
checks = report.get("checks")

if not isinstance(domain, str) or "." not in domain or domain.startswith(".") or domain.endswith("."):
    fail("report.domain is missing or invalid")
if not isinstance(target_ip, str):
    fail("report.target_ip is missing or invalid")
try:
    ipaddress.ip_address(target_ip)
except ValueError:
    fail("report.target_ip is not an IP address")
if not isinstance(proxied, bool):
    fail("report.proxied must be a boolean")
if not isinstance(verified_at, str):
    fail("report.verified_at_utc is missing")
try:
    datetime.fromisoformat(verified_at.replace("Z", "+00:00"))
except ValueError:
    fail("report.verified_at_utc is not ISO-8601")
if not isinstance(checks, list) or not all(isinstance(item, str) for item in checks):
    fail("report.checks must be a string list")

missing = sorted(required_checks.difference(checks))
if missing:
    fail("live verification report is missing checks: " + ", ".join(missing))

env_domain = env.get("DOMAIN", "")
if not env_domain:
    fail("env file is missing DOMAIN")
if domain != env_domain:
    fail(f"report.domain ({domain}) does not match env DOMAIN ({env_domain})")

env_proxied = env.get("PROXIED", "false").lower()
if env_proxied not in {"true", "false"}:
    fail("env PROXIED must be true or false")
if proxied != (env_proxied == "true"):
    fail("report.proxied does not match env PROXIED")

target_region = env.get("TARGET_REGION", "").lower()
if env.get("TARGET_IP"):
    candidate_ips = [env["TARGET_IP"]]
elif target_region in {"jp", "japan"}:
    candidate_ips = [env.get("JP_TARGET_IP", "")]
elif target_region in {"hk", "hongkong"}:
    candidate_ips = [env.get("HK_TARGET_IP", "")]
elif target_region in {"", "auto"}:
    candidate_ips = [env.get("JP_TARGET_IP", ""), env.get("HK_TARGET_IP", "")]
else:
    fail("env TARGET_REGION must be auto, jp, hk, or empty")
candidate_ips = [item for item in candidate_ips if item]
if not candidate_ips:
    fail("env file has no candidate target IP for the selected region")
if target_ip not in candidate_ips:
    fail(f"report.target_ip ({target_ip}) does not match configured target IPs")

print(f"OK: completion evidence proves {domain} on {target_ip}")
PY

ok "1G cloud deployment completion audit passed"
