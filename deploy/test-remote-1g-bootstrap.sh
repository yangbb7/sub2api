#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/remote-1g-bootstrap.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

mkdir -p "${tmp_dir}/bin" "${tmp_dir}/state" "${tmp_dir}/remote"

cat > "${tmp_dir}/bin/id" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  -u) printf '0\n' ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

cat > "${tmp_dir}/bin/apt-get" <<'EOF'
#!/usr/bin/env sh
set -eu
state="${MOCK_STATE_DIR}"
printf '%s\n' "$*" >> "${state}/apt.log"
case "$*" in
  *docker-compose-plugin*)
    if [ "${MOCK_PACKAGE_DOCKER_FAIL:-false}" = true ]; then
      exit 1
    fi
    touch "${state}/package-docker-ready"
    ;;
esac
exit 0
EOF

cat > "${tmp_dir}/bin/docker" <<'EOF'
#!/usr/bin/env sh
set -eu
state="${MOCK_STATE_DIR}"
case "${1:-}" in
  compose)
    if [ "${2:-}" = version ] && { [ -f "${state}/package-docker-ready" ] || [ -f "${state}/get-docker-ready" ]; }; then
      printf 'Docker Compose version mock\n'
      exit 0
    fi
    exit 1
    ;;
  info)
    if [ -f "${state}/package-docker-ready" ] || [ -f "${state}/get-docker-ready" ]; then
      printf 'DockerRootDir: /var/lib/docker\n'
      exit 0
    fi
    exit 1
    ;;
  --version)
    printf 'Docker version mock\n'
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat > "${tmp_dir}/bin/curl" <<'EOF'
#!/usr/bin/env sh
set -eu
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
test -n "${out}"
cat > "${out}" <<EOS
#!/usr/bin/env sh
touch "${MOCK_STATE_DIR}/get-docker-ready"
EOS
EOF

cat > "${tmp_dir}/bin/systemctl" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF

cat > "${tmp_dir}/bin/swapon" <<'EOF'
#!/usr/bin/env sh
case "$*" in
  *--show*) printf '/swapfile\n' ;;
esac
exit 0
EOF

chmod +x "${tmp_dir}/bin/"*

run_bootstrap() {
  rm -f "${tmp_dir}/state/"*
  PATH="${tmp_dir}/bin:${PATH}" \
    MOCK_STATE_DIR="${tmp_dir}/state" \
    REMOTE_DIR="${tmp_dir}/remote/gateway" \
    SWAP_SIZE=512M \
    "$@"
}

expect_success() {
  local name="$1"
  shift
  local output

  output="$(run_bootstrap "$@" 2>&1)"
  if ! printf '%s\n' "${output}" | grep -q "Bootstrap complete"; then
    echo "FAIL: ${name}: expected bootstrap success" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  echo "OK: ${name}"
}

expect_success "package docker install" "${SCRIPT_UNDER_TEST}"
if [ ! -f "${tmp_dir}/state/package-docker-ready" ]; then
  echo "FAIL: package Docker install did not run" >&2
  exit 1
fi

expect_success "fallback to get.docker.com script" \
  env MOCK_PACKAGE_DOCKER_FAIL=true "${SCRIPT_UNDER_TEST}"
if [ ! -f "${tmp_dir}/state/get-docker-ready" ]; then
  echo "FAIL: get.docker fallback did not run" >&2
  exit 1
fi

echo "Remote bootstrap mock tests passed"
