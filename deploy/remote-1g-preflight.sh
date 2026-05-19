#!/usr/bin/env sh
set -eu

REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
EXPECTED_PLATFORM="${EXPECTED_PLATFORM:-linux/amd64}"
MIN_FREE_KB="${MIN_FREE_KB:-3145728}"
MIN_DOCKER_FREE_KB="${MIN_DOCKER_FREE_KB:-4194304}"

fail() {
  echo "Preflight failed: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "deploy requires root SSH access"
}

check_arch() {
  arch="$(uname -m)"
  case "${EXPECTED_PLATFORM}" in
    linux/amd64)
      case "${arch}" in x86_64|amd64) return ;; esac
      ;;
    linux/arm64)
      case "${arch}" in aarch64|arm64) return ;; esac
      ;;
    *)
      fail "unsupported EXPECTED_PLATFORM=${EXPECTED_PLATFORM}"
      ;;
  esac
  fail "server arch ${arch} does not match ${EXPECTED_PLATFORM}"
}

check_package_manager() {
  command -v apt-get >/dev/null 2>&1 && return
  command -v dnf >/dev/null 2>&1 && return
  command -v yum >/dev/null 2>&1 && return
  fail "apt-get/dnf/yum not found"
}

disk_parent() {
  parent="${1:-/}"
  [ -n "${parent}" ] || parent="/"
  while [ ! -d "${parent}" ] && [ "${parent}" != "/" ]; do
    parent="${parent%/*}"
    [ -n "${parent}" ] || parent="/"
  done
  printf '%s\n' "${parent}"
}

check_free_kb() {
  path="$1"
  min_free_kb="$2"
  label="$3"
  parent="$(disk_parent "${path}")"
  free_kb="$(df -Pk "${parent}" | awk 'NR==2 {print $4}')"
  [ -n "${free_kb}" ] || fail "cannot read free disk space for ${label} at ${parent}"
  if [ "${free_kb}" -lt "${min_free_kb}" ]; then
    fail "free disk for ${label} at ${parent} is ${free_kb}KB, need at least ${min_free_kb}KB"
  fi
}

check_disk() {
  check_free_kb "${REMOTE_DIR}" "${MIN_FREE_KB}" "deploy directory"
}

docker_root_dir() {
  if command -v docker >/dev/null 2>&1; then
    root_dir="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    if [ -n "${root_dir}" ]; then
      printf '%s\n' "${root_dir}"
      return
    fi
  fi
  printf '%s\n' "/var/lib/docker"
}

check_docker_disk() {
  check_free_kb "$(docker_root_dir)" "${MIN_DOCKER_FREE_KB}" "Docker data"
}

check_memory() {
  if [ -r /proc/meminfo ]; then
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    [ "${mem_kb:-0}" -ge 750000 ] || fail "memory is ${mem_kb:-0}KB, too small for this profile"
  fi
}

own_caddy_running() {
  command -v docker >/dev/null 2>&1 || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx gateway-caddy
}

proc_tcp_ports_listening() {
  for file in ${PROC_NET_TCP_FILES:-/proc/net/tcp /proc/net/tcp6}; do
    [ -r "${file}" ] || continue
    awk '
      NR > 1 {
        count = split($2, local_addr, ":")
        port = local_addr[count]
        if ($4 == "0A" && (port == "0050" || port == "01BB")) {
          found = 1
        }
      }
      END { exit found ? 0 : 1 }
    ' "${file}" && return 0
  done
  return 1
}

check_ports() {
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn | awk '{print $4}' | grep -Eq '(:80|:443)$'; then
      own_caddy_running && return
      fail "port 80 or 443 is already listening"
    fi
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    if netstat -ltn | awk '{print $4}' | grep -Eq '(:80|:443)$'; then
      own_caddy_running && return
      fail "port 80 or 443 is already listening"
    fi
  fi

  if proc_tcp_ports_listening; then
    own_caddy_running && return
    fail "port 80 or 443 is already listening"
  fi
}

need_root
check_arch
check_package_manager
check_disk
check_docker_disk
check_memory
check_ports

echo "Preflight complete: ${EXPECTED_PLATFORM}, ${REMOTE_DIR}"
