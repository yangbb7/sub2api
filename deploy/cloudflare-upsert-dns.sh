#!/usr/bin/env bash
set -euo pipefail

CF_API_TOKEN="${CF_API_TOKEN:-}"
DOMAIN="${DOMAIN:-}"
TARGET_IP="${TARGET_IP:-}"
PROXIED="${PROXIED:-false}"
TTL="${TTL:-1}"
CHECK_ONLY="${CHECK_ONLY:-false}"
WRITE_CHECK_ONLY="${WRITE_CHECK_ONLY:-false}"

validate_bool() {
  local name="$1"
  local value="$2"
  case "${value}" in
    true|false) ;;
    *)
      echo "${name} must be true or false" >&2
      exit 1
      ;;
  esac
}

validate_ipv4() {
  local name="$1"
  local value="$2"
  local first second third fourth
  local octet
  if [[ ! "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${name} must be an IPv4 address" >&2
    exit 1
  fi
  IFS=. read -r first second third fourth <<< "${value}"
  for octet in "${first}" "${second}" "${third}" "${fourth}"; do
    if [ "${#octet}" -gt 3 ] || [ "$((10#${octet}))" -gt 255 ]; then
      echo "${name} must be an IPv4 address" >&2
      exit 1
    fi
  done
}

validate_domain() {
  local name="$1"
  local value="$2"
  local label
  local labels
  if [ -z "${value}" ] || [ "${#value}" -gt 253 ] || [[ "${value}" != *.* ]] || [[ "${value}" == .* || "${value}" == *. || "${value}" == *..* ]] || [[ ! "${value}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "${name} must be a hostname with valid DNS labels, for example api.example.com" >&2
    exit 1
  fi
  IFS=. read -r -a labels <<< "${value}"
  for label in "${labels[@]}"; do
    if [ -z "${label}" ] || [ "${#label}" -gt 63 ] || [[ ! "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
      echo "${name} must be a hostname with valid DNS labels, for example api.example.com" >&2
      exit 1
    fi
  done
  label="${labels[$((${#labels[@]} - 1))]}"
  if [[ ! "${label}" =~ ^[A-Za-z]{2,63}$ ]]; then
    echo "${name} must use a valid alphabetic top-level domain, for example api.example.com" >&2
    exit 1
  fi
}

validate_ttl() {
  local value="$1"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "TTL must be 1 for automatic or an integer from 60 to 86400" >&2
    exit 1
  fi
  if [ "${value}" -ne 1 ] && { [ "${value}" -lt 60 ] || [ "${value}" -gt 86400 ]; }; then
    echo "TTL must be 1 for automatic or an integer from 60 to 86400" >&2
    exit 1
  fi
}

validate_proxied_ttl() {
  if [ "${PROXIED}" = true ] && [ "${TTL}" -ne 1 ]; then
    echo "TTL must be 1 when PROXIED=true because Cloudflare proxied records use automatic TTL" >&2
    exit 1
  fi
}

if [ -z "${CF_API_TOKEN}" ] || [ -z "${DOMAIN}" ] || [ -z "${TARGET_IP}" ]; then
  cat >&2 <<'EOF'
Required environment:
  CF_API_TOKEN  Cloudflare API token with Zone:Read and DNS:Edit
  DOMAIN        Full hostname, for example api.example.com
  TARGET_IP     Origin server public IPv4

Optional:
  PROXIED=false
  TTL=1
  CHECK_ONLY=false
  WRITE_CHECK_ONLY=false  # create and delete a temporary TXT record to verify DNS Write
  CF_ZONE_ID    Skip zone lookup and use this Cloudflare zone id
EOF
  exit 1
fi

validate_domain DOMAIN "${DOMAIN}"
validate_ipv4 TARGET_IP "${TARGET_IP}"
validate_bool PROXIED "${PROXIED}"
validate_bool CHECK_ONLY "${CHECK_ONLY}"
validate_bool WRITE_CHECK_ONLY "${WRITE_CHECK_ONLY}"
validate_ttl "${TTL}"
validate_proxied_ttl

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to call the Cloudflare API" >&2
  exit 1
fi

api() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  if [ -n "${data}" ]; then
    curl -fsS -X "${method}" "https://api.cloudflare.com/client/v4${url}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "${data}"
  else
    curl -fsS -X "${method}" "https://api.cloudflare.com/client/v4${url}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json"
  fi
}

cf_json() {
  local mode="$1"
  python3 -c '
import json
import sys

mode = sys.argv[1]
data = json.load(sys.stdin)
if not data.get("success", False):
    errors = data.get("errors") or []
    message = "; ".join(str(item.get("message", item)) for item in errors) or "unknown Cloudflare API error"
    print(f"Cloudflare API error: {message}", file=sys.stderr)
    sys.exit(1)

if mode == "first_id":
    result = data.get("result") or []
    print(result[0].get("id", "") if result else "")
elif mode == "ids":
    result = data.get("result") or []
    for item in result:
        if isinstance(item, dict) and item.get("id"):
            print(item["id"])
elif mode == "a_details":
    result = data.get("result") or []
    for item in result:
        if not isinstance(item, dict):
            continue
        if item.get("id"):
            proxied = item.get("proxied", False)
            print("{}\t{}\t{}".format(item.get("id", ""), item.get("content", ""), str(bool(proxied)).lower()))
elif mode == "result_id":
    result = data.get("result") or {}
    print(result.get("id", "") if isinstance(result, dict) else "")
elif mode == "ok":
    print("ok")
else:
    print(f"Unknown parser mode: {mode}", file=sys.stderr)
    sys.exit(1)
' "$mode"
}

find_zone() {
  local host="$1"
  while [ "${host}" != "${host#*.}" ]; do
    local response
    response="$(api GET "/zones?name=${host}&status=active")" || return 1
    local zone_id
    zone_id="$(printf '%s' "${response}" | cf_json first_id)" || return 1
    if [ -n "${zone_id}" ]; then
      printf '%s\n' "${zone_id}"
      return
    fi
    host="${host#*.}"
  done
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to parse Cloudflare API responses" >&2
  exit 1
fi

if [ -n "${CF_ZONE_ID:-}" ]; then
  ZONE_ID="${CF_ZONE_ID}"
else
  ZONE_ID="$(find_zone "${DOMAIN}")" || exit 1
fi
if [ -z "${ZONE_ID}" ]; then
  echo "Could not find Cloudflare zone for ${DOMAIN}" >&2
  exit 1
fi

write_check_record_id=""
cleanup_write_check() {
  if [ -n "${write_check_record_id}" ]; then
    api DELETE "/zones/${ZONE_ID}/dns_records/${write_check_record_id}" >/dev/null 2>&1 || true
  fi
}
trap cleanup_write_check EXIT

record_ids_for_type() {
  local type="$1"
  local response
  response="$(api GET "/zones/${ZONE_ID}/dns_records?type=${type}&name=${DOMAIN}")" || return 1
  printf '%s' "${response}" | cf_json ids
}

a_record_details() {
  local response
  response="$(api GET "/zones/${ZONE_ID}/dns_records?type=A&name=${DOMAIN}")" || return 1
  printf '%s' "${response}" | cf_json a_details
}

count_ids() {
  if [ -z "$1" ]; then
    printf '0\n'
  else
    printf '%s\n' "$1" | awk 'NF {count++} END {print count + 0}'
  fi
}

cname_ids="$(record_ids_for_type CNAME)" || exit 1
cname_count="$(count_ids "${cname_ids}")"
if [ "${cname_count}" -gt 0 ]; then
  echo "Cloudflare DNS has a CNAME record for ${DOMAIN}; remove it before creating an A record" >&2
  exit 1
fi

aaaa_ids="$(record_ids_for_type AAAA)" || exit 1
aaaa_count="$(count_ids "${aaaa_ids}")"
if [ "${aaaa_count}" -gt 0 ]; then
  echo "Cloudflare DNS has ${aaaa_count} AAAA record(s) for ${DOMAIN}; remove them before deployment to avoid IPv6 traffic hitting an old origin" >&2
  exit 1
fi

if [ "${WRITE_CHECK_ONLY}" = true ]; then
  write_check_payload="$(DOMAIN="${DOMAIN}" TARGET_IP="${TARGET_IP}" python3 -c 'import json,os; print(json.dumps({"type":"TXT","name":os.environ["DOMAIN"],"content":"gateway deploy write check for "+os.environ["TARGET_IP"],"ttl":60}))')"
  write_check_response="$(api POST "/zones/${ZONE_ID}/dns_records" "${write_check_payload}")" || exit 1
  write_check_record_id="$(printf '%s' "${write_check_response}" | cf_json result_id)" || exit 1
  if [ -z "${write_check_record_id}" ]; then
    echo "Cloudflare DNS write check failed: create response did not include a record id" >&2
    exit 1
  fi
  api DELETE "/zones/${ZONE_ID}/dns_records/${write_check_record_id}" | cf_json ok >/dev/null
  write_check_record_id=""
  echo "Cloudflare DNS write access OK: temporary TXT record created and removed"
  exit 0
fi

record_ids="$(record_ids_for_type A)" || exit 1
record_count=0
record_id=""
if [ -n "${record_ids}" ]; then
  record_count="$(count_ids "${record_ids}")"
  record_id="$(printf '%s\n' "${record_ids}" | awk 'NF {print; exit}')"
fi
if [ "${record_count}" -gt 1 ]; then
  echo "Cloudflare DNS has ${record_count} A records for ${DOMAIN}; clean up duplicates before deployment to avoid mixed origin traffic" >&2
  exit 1
fi

if [ "${CHECK_ONLY}" = true ]; then
  if [ -n "${record_id}" ]; then
    a_details="$(a_record_details)" || exit 1
    record_content="$(printf '%s\n' "${a_details}" | awk -F '\t' -v id="${record_id}" '$1 == id {print $2; exit}')"
    record_proxied="$(printf '%s\n' "${a_details}" | awk -F '\t' -v id="${record_id}" '$1 == id {print $3; exit}')"
    if [ "${record_content}" != "${TARGET_IP}" ]; then
      echo "Cloudflare DNS A record mismatch for ${DOMAIN}: expected ${TARGET_IP}, got ${record_content:-empty}" >&2
      exit 1
    fi
    if [ "${record_proxied}" != "${PROXIED}" ]; then
      echo "Cloudflare DNS proxied mismatch for ${DOMAIN}: expected ${PROXIED}, got ${record_proxied:-empty}" >&2
      exit 1
    fi
    echo "Cloudflare DNS access OK: ${DOMAIN} A -> ${TARGET_IP} (proxied=${PROXIED})"
  else
    echo "Cloudflare DNS access OK: ${DOMAIN} record can be created"
  fi
  exit 0
fi

payload="$(python3 -c 'import json,os; print(json.dumps({"type":"A","name":os.environ["DOMAIN"],"content":os.environ["TARGET_IP"],"ttl":int(os.environ.get("TTL","1")),"proxied":os.environ.get("PROXIED","false").lower()=="true"}))')"

if [ -n "${record_id}" ]; then
  api PUT "/zones/${ZONE_ID}/dns_records/${record_id}" "${payload}" | cf_json ok >/dev/null
  echo "Updated DNS A ${DOMAIN} -> ${TARGET_IP} (proxied=${PROXIED})"
else
  api POST "/zones/${ZONE_ID}/dns_records" "${payload}" | cf_json ok >/dev/null
  echo "Created DNS A ${DOMAIN} -> ${TARGET_IP} (proxied=${PROXIED})"
fi
