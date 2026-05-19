#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/cloudflare-upsert-dns.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

mkdir -p "${tmp_dir}/bin"
cat > "${tmp_dir}/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
url=""
data=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -X)
      method="$2"
      shift 2
      ;;
    --data)
      data="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    -fsS)
      shift
      ;;
    https://api.cloudflare.com/client/v4*)
      url="${1#https://api.cloudflare.com/client/v4}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

scenario="${CF_MOCK_SCENARIO:-empty}"

json_ok() {
  printf '{"success":true,"result":%s}\n' "$1"
}

case "${method} ${url}" in
  "GET /zones/"*"dns_records?type=CNAME&name="*)
    if [ "${scenario}" = "cname_conflict" ]; then
      json_ok '[{"id":"cname-id"}]'
    else
      json_ok '[]'
    fi
    ;;
  "GET /zones/"*"dns_records?type=AAAA&name="*)
    if [ "${scenario}" = "aaaa_conflict" ]; then
      json_ok '[{"id":"aaaa-id"}]'
    else
      json_ok '[]'
    fi
    ;;
  "GET /zones/"*"dns_records?type=A&name="*)
    case "${scenario}" in
      duplicate_a) json_ok '[{"id":"a-id-1"},{"id":"a-id-2"}]' ;;
      existing_a) json_ok '[{"id":"a-id-1","content":"203.0.113.10","proxied":false}]' ;;
      existing_a_wrong_ip) json_ok '[{"id":"a-id-1","content":"203.0.113.11","proxied":false}]' ;;
      existing_a_wrong_proxy) json_ok '[{"id":"a-id-1","content":"203.0.113.10","proxied":true}]' ;;
      *) json_ok '[]' ;;
    esac
    ;;
  "POST /zones/"*"dns_records")
    case "${data}" in
      *'"type": "TXT"'*) json_ok '{"id":"txt-id"}' ;;
      *'"type": "A"'*) json_ok '{"id":"created-a-id"}' ;;
      *) printf '{"success":false,"errors":[{"message":"unexpected POST payload"}]}\n' ;;
    esac
    ;;
  "PUT /zones/"*"dns_records/a-id-1")
    json_ok '{"id":"a-id-1"}'
    ;;
  "DELETE /zones/"*"dns_records/txt-id")
    json_ok '{"id":"txt-id"}'
    ;;
  *)
    printf '{"success":false,"errors":[{"message":"unexpected mock request: %s %s"}]}\n' "${method}" "${url}"
    ;;
esac
MOCK_CURL
chmod +x "${tmp_dir}/bin/curl"

run_script() {
  PATH="${tmp_dir}/bin:${PATH}" \
    CF_API_TOKEN=test-token \
    CF_ZONE_ID=zone-id \
    DOMAIN=api.example.com \
    TARGET_IP=203.0.113.10 \
    "$@"
}

expect_success() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  output="$(run_script "$@" 2>&1)"
  if ! printf '%s\n' "${output}" | grep -q "${expected}"; then
    echo "FAIL: ${name}: expected output to contain ${expected}" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  echo "OK: ${name}"
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output

  set +e
  output="$(run_script "$@" 2>&1)"
  status=$?
  set -e
  if [ "${status}" -eq 0 ]; then
    echo "FAIL: ${name}: expected failure" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  if ! printf '%s\n' "${output}" | grep -q "${expected}"; then
    echo "FAIL: ${name}: expected output to contain ${expected}" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  echo "OK: ${name}"
}

expect_success "write check" "Cloudflare DNS write access OK" \
  env CF_MOCK_SCENARIO=empty WRITE_CHECK_ONLY=true "${SCRIPT_UNDER_TEST}"
expect_success "create A record" "Created DNS A api.example.com -> 203.0.113.10" \
  env CF_MOCK_SCENARIO=empty "${SCRIPT_UNDER_TEST}"
expect_success "update A record" "Updated DNS A api.example.com -> 203.0.113.10" \
  env CF_MOCK_SCENARIO=existing_a "${SCRIPT_UNDER_TEST}"
expect_success "check existing A record target" "Cloudflare DNS access OK: api.example.com A -> 203.0.113.10" \
  env CF_MOCK_SCENARIO=existing_a CHECK_ONLY=true "${SCRIPT_UNDER_TEST}"
expect_failure "reject check-only wrong A target" "A record mismatch" \
  env CF_MOCK_SCENARIO=existing_a_wrong_ip CHECK_ONLY=true "${SCRIPT_UNDER_TEST}"
expect_failure "reject check-only wrong proxied state" "proxied mismatch" \
  env CF_MOCK_SCENARIO=existing_a_wrong_proxy CHECK_ONLY=true "${SCRIPT_UNDER_TEST}"
expect_failure "reject CNAME conflict" "CNAME record" \
  env CF_MOCK_SCENARIO=cname_conflict "${SCRIPT_UNDER_TEST}"
expect_failure "reject AAAA conflict" "AAAA record" \
  env CF_MOCK_SCENARIO=aaaa_conflict "${SCRIPT_UNDER_TEST}"
expect_failure "reject duplicate A records" "2 A records" \
  env CF_MOCK_SCENARIO=duplicate_a "${SCRIPT_UNDER_TEST}"
expect_failure "reject proxied concrete TTL" "TTL must be 1 when PROXIED=true" \
  env PROXIED=true TTL=300 "${SCRIPT_UNDER_TEST}"

echo "Cloudflare DNS script mock tests passed"
