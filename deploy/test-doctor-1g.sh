#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/doctor-1g.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

run_doctor() {
  env \
    SKIP_DNS=true \
    ROLLBACK_ON_FAILURE=false \
    DOMAIN=api.example.net \
    TARGET_IP=45.76.12.34 \
    SSH_TARGET=root@45.76.12.34 \
    ADMIN_EMAIL=admin@example.net \
    SWAP_SIZE=1024M \
    MIN_FREE_KB=1 \
    MIN_DOCKER_FREE_KB=1 \
    "$@"
}

expect_success() {
  local name="$1"
  shift
  local output

  output="$(run_doctor "$@" "${SCRIPT_UNDER_TEST}" 2>&1)"
  if ! printf '%s\n' "${output}" | grep -q "1G deployment doctor passed"; then
    echo "FAIL: ${name}: expected doctor success" >&2
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
  output="$(run_doctor "$@" "${SCRIPT_UNDER_TEST}" 2>&1)"
  status=$?
  set -e
  if [ "${status}" -eq 0 ]; then
    echo "FAIL: ${name}: expected doctor failure" >&2
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

expect_success "valid direct target"
expect_success "target ip inferred from ssh target" env TARGET_IP=
expect_success "ssh pass alias" env SSH_PASS=sample_password

cat > "${tmp_dir}/sample.env" <<'EOF'
SSH_TARGET=root@203.0.113.10
TARGET_IP=203.0.113.10
DOMAIN=api.example.com
SKIP_DNS=true
EOF

expect_success "explicit env overrides env file target" \
  env ENV_FILE="${tmp_dir}/sample.env" SSH_TARGET=root@45.76.12.34 TARGET_IP=45.76.12.34 DOMAIN=api.example.net

expect_failure "placeholder ssh target" "SSH_TARGET is still the documentation placeholder" \
  env SSH_TARGET=root@203.0.113.10 TARGET_IP=45.76.12.34
expect_failure "placeholder target ip" "TARGET_IP is still the documentation placeholder" \
  env SSH_TARGET=root@45.76.12.34 TARGET_IP=203.0.113.10
expect_failure "placeholder domain" "DOMAIN is still the documentation placeholder" \
  env DOMAIN=api.example.com
expect_failure "bad rollback boolean" "ROLLBACK_ON_FAILURE must be true or false" \
  env ROLLBACK_ON_FAILURE=maybe
expect_failure "bad remote sudo mode" "REMOTE_SUDO must be auto, true, or false" \
  env REMOTE_SUDO=maybe
expect_failure "local build strategy rejected" "always builds on the remote VPS" \
  env BUILD_STRATEGY=local
expect_failure "bad Docker install method" "DOCKER_INSTALL_METHOD must be auto, package, or get-docker" \
  env DOCKER_INSTALL_METHOD=magic
expect_failure "bad build gomaxprocs" "BUILD_GOMAXPROCS must be a positive integer" \
  env BUILD_GOMAXPROCS=zero
expect_failure "bad proxied ttl" "TTL must be 1 when PROXIED=true" \
  env PROXIED=true TTL=300
expect_failure "missing Cloudflare token when DNS enabled" "CF_API_TOKEN is required unless SKIP_DNS=true" \
  env SKIP_DNS=false
expect_failure "bad admin email" "ADMIN_EMAIL must be a valid email address" \
  env ADMIN_EMAIL=not-an-email
expect_failure "unsafe admin password token" "ADMIN_PASSWORD contains characters" \
  env "ADMIN_PASSWORD=bad password"
expect_failure "missing ssh key" "SSH_KEY does not exist" \
  env SSH_KEY="${tmp_dir}/missing.key"
expect_failure "conflicting ssh password aliases" "SSH_PASSWORD and SSH_PASS must not differ" \
  env SSH_PASSWORD=one SSH_PASS=two

echo "1G doctor validation tests passed"
