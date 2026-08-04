#!/usr/bin/env bash
# Runs only a fixed synthetic /v1/responses payload. It never reads a user
# prompt, prints an API key, or creates a public origin bypass.
set -euo pipefail

require_env() {
  local name="$1"
  [ -n "${!name:-}" ] || { echo "${name} is required" >&2; exit 2; }
}

require_env PUBLIC_BASE_URL
require_env PROBE_API_KEY

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 2
fi

PROBE_MODEL="${PROBE_MODEL:-gpt-5}"
PROBE_TIMEOUT_SECONDS="${PROBE_TIMEOUT_SECONDS:-15}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

new_request_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    # RFC 4122-shaped and unique enough for a short-lived operator probe.
    printf '00000000-0000-4000-8000-%012d\n' "$(( $(date +%s) % 1000000000000 ))"
  fi
}

run_probe() {
  local route="$1"
  local base_url="$2"
  local request_id header_file metrics cf_ray
  request_id="$(new_request_id)"
  header_file="${TMP_DIR}/${route}.headers"

  local -a auth_args=(
    --silent --show-error --no-buffer
    --connect-timeout 5 --max-time "${PROBE_TIMEOUT_SECONDS}"
    -D "${header_file}" -o /dev/null
    -H "Authorization: Bearer ${PROBE_API_KEY}"
    -H 'Content-Type: application/json'
    -H "X-Request-ID: ${request_id}"
    -H "Idempotency-Key: stream-probe-${request_id}"
    --data-binary "{\"model\":\"${PROBE_MODEL}\",\"input\":\"synthetic stream isolation probe\",\"stream\":true}"
  )

  if [ "${route}" = origin ]; then
    # The caller must provide mTLS material. The script deliberately has no
    # option for an unauthenticated origin URL or a DNS/host bypass.
    require_env ORIGIN_PROBE_MTLS_REQUIRED
    require_env ORIGIN_PROBE_CLIENT_CERT
    require_env ORIGIN_PROBE_CLIENT_KEY
    [ "${ORIGIN_PROBE_MTLS_REQUIRED}" = true ] || {
      echo "ORIGIN_PROBE_MTLS_REQUIRED must be true for direct-origin probes" >&2
      exit 2
    }
    auth_args+=(--cert "${ORIGIN_PROBE_CLIENT_CERT}" --key "${ORIGIN_PROBE_CLIENT_KEY}")
  fi

  metrics="$(curl "${auth_args[@]}" -w '%{http_code} %{time_starttransfer}' "${base_url%/}/v1/responses" || true)"
  cf_ray="$(awk 'BEGIN{IGNORECASE=1} /^cf-ray:/ {gsub("\\r", ""); print $2; exit}' "${header_file}" 2>/dev/null || true)"
  printf 'route=%s request_id=%s http_code=%s ttfb_seconds=%s cf_ray=%s\n' \
    "${route}" "${request_id}" "${metrics%% *}" "${metrics#* }" "${cf_ray:-none}"
}

run_probe public "${PUBLIC_BASE_URL}"

if [ -n "${ORIGIN_PROBE_URL:-}" ]; then
  run_probe origin "${ORIGIN_PROBE_URL}"
fi
