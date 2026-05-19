#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/remote-1g-preflight.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/fs/opt"

cat > "${tmp_dir}/bin/id" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  -u) printf '0\n' ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

cat > "${tmp_dir}/bin/uname" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  -m) printf '%s\n' "${MOCK_ARCH:-x86_64}" ;;
  *) /usr/bin/uname "$@" ;;
esac
EOF

cat > "${tmp_dir}/bin/apt-get" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF

cat > "${tmp_dir}/bin/docker" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  info)
    printf '%s\n' "${MOCK_DOCKER_ROOT:-/var/lib/docker}"
    ;;
  ps)
    if [ "${MOCK_OWN_CADDY:-false}" = true ]; then
      printf 'gateway-caddy\n'
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat > "${tmp_dir}/bin/df" <<'EOF'
#!/usr/bin/env sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'mockfs 10000000 1 %s 1%% /\n' "${MOCK_FREE_KB:-9999999}"
EOF

cat > "${tmp_dir}/bin/ss" <<'EOF'
#!/usr/bin/env sh
if [ "${MOCK_SS_CONFLICT:-false}" = true ]; then
  printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
  printf 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*\n'
else
  printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
fi
EOF

chmod +x "${tmp_dir}/bin/"*

run_preflight() {
  PATH="${tmp_dir}/bin:${PATH}" \
    REMOTE_DIR="${tmp_dir}/fs/opt/gateway" \
    MIN_FREE_KB=1000 \
    MIN_DOCKER_FREE_KB=1000 \
    PROC_NET_TCP_FILES="${PROC_NET_TCP_FILES:-}" \
    "$@"
}

expect_success() {
  local name="$1"
  shift
  local output

  output="$(run_preflight "$@" 2>&1)"
  if ! printf '%s\n' "${output}" | grep -q "Preflight complete"; then
    echo "FAIL: ${name}: expected preflight success" >&2
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
  output="$(run_preflight "$@" 2>&1)"
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

expect_success "happy path" "${SCRIPT_UNDER_TEST}"
expect_failure "arch mismatch" "does not match linux/arm64" \
  env MOCK_ARCH=x86_64 EXPECTED_PLATFORM=linux/arm64 "${SCRIPT_UNDER_TEST}"
expect_failure "low deploy disk" "free disk for deploy directory" \
  env MOCK_FREE_KB=10 "${SCRIPT_UNDER_TEST}"
expect_failure "ss port conflict" "port 80 or 443 is already listening" \
  env MOCK_SS_CONFLICT=true "${SCRIPT_UNDER_TEST}"
expect_success "own caddy may already bind ports" \
  env MOCK_SS_CONFLICT=true MOCK_OWN_CADDY=true "${SCRIPT_UNDER_TEST}"

rm -f "${tmp_dir}/bin/ss"
cat > "${tmp_dir}/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 1 0000000000000000 100 0 0 10 0
EOF
expect_failure "proc tcp port conflict" "port 80 or 443 is already listening" \
  env PROC_NET_TCP_FILES="${tmp_dir}/tcp" "${SCRIPT_UNDER_TEST}"

echo "Remote preflight mock tests passed"
