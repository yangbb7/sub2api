#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/probe-frontend.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

mkdir -p "${tmp_dir}/bin"
cat > "${tmp_dir}/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env sh
set -eu

scenario="${PROBE_MOCK_SCENARIO:-happy}"
resolve_value=""
url=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resolve)
      resolve_value="$2"
      shift 2
      ;;
    --connect-timeout|--max-time)
      shift 2
      ;;
    -fsS)
      shift
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "${PROBE_MOCK_LOG:-}" ]; then
  printf '%s resolve=%s\n' "${url}" "${resolve_value}" >> "${PROBE_MOCK_LOG}"
fi

case "${url}" in
  */health)
    if [ "${scenario}" = "health_fail" ]; then
      exit 22
    fi
    printf 'ok\n'
    ;;
  */login)
    case "${scenario}" in
      missing_app_root)
        printf '<html><body>no app</body></html>\n'
        ;;
      missing_asset)
        printf '<html><body><div id="app"></div></body></html>\n'
        ;;
      absolute_asset)
        printf '<html><body><div id="app"></div><script type="module" src="https://cdn.example.test/assets/app.123.js"></script></body></html>\n'
        ;;
      *)
        printf '<html><body><div id="app"></div><script type="module" src="/assets/app.123.js"></script></body></html>\n'
        ;;
    esac
    ;;
  */assets/*.js)
    if [ "${scenario}" = "asset_fail" ]; then
      exit 22
    fi
    printf 'console.log("ok")\n'
    ;;
  *)
    printf 'unexpected url: %s\n' "${url}" >&2
    exit 22
    ;;
esac
MOCK_CURL
chmod +x "${tmp_dir}/bin/curl"

run_probe() {
  PATH="${tmp_dir}/bin:${PATH}" \
    BASE_URL=https://api.example.test \
    ATTEMPTS=1 \
    CONNECT_TIMEOUT=1 \
    MAX_TIME=1 \
    "$@"
}

expect_success() {
  local name="$1"
  shift
  local output

  output="$(run_probe "$@" "${SCRIPT_UNDER_TEST}" 2>&1)"
  if ! printf '%s\n' "${output}" | grep -q "Frontend probe passed"; then
    echo "FAIL: ${name}: expected probe success" >&2
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
  local status

  set +e
  output="$(run_probe "$@" "${SCRIPT_UNDER_TEST}" 2>&1)"
  status=$?
  set -e
  if [ "${status}" -eq 0 ]; then
    echo "FAIL: ${name}: expected probe failure" >&2
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

expect_success "happy path"
expect_success "absolute asset URL" env PROBE_MOCK_SCENARIO=absolute_asset
expect_success "health disabled skips health endpoint" env PROBE_MOCK_SCENARIO=health_fail CHECK_HEALTH=false
expect_failure "invalid health flag" "CHECK_HEALTH must be true or false" env CHECK_HEALTH=maybe
expect_failure "missing app root" "login page did not include the Vue app root" env PROBE_MOCK_SCENARIO=missing_app_root
expect_failure "missing asset reference" "login page did not reference a built frontend JS asset" env PROBE_MOCK_SCENARIO=missing_asset
expect_failure "asset fetch failure" "Frontend probe failed" env PROBE_MOCK_SCENARIO=asset_fail

resolve_log="${tmp_dir}/resolve.log"
expect_success "curl resolve is forwarded" env PROBE_MOCK_LOG="${resolve_log}" CURL_RESOLVE=api.example.test:443:203.0.113.10
if ! grep -q 'resolve=api.example.test:443:203.0.113.10' "${resolve_log}"; then
  echo "FAIL: curl resolve is forwarded: mock curl did not receive --resolve" >&2
  cat "${resolve_log}" >&2
  exit 1
fi

echo "Frontend probe mock tests passed"
