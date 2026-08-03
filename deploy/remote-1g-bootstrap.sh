#!/usr/bin/env bash
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SWAP_SIZE_MB=""
DOCKER_INSTALL_METHOD="${DOCKER_INSTALL_METHOD:-auto}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "remote-1g-bootstrap.sh must run as root" >&2
    exit 1
  fi
}

parse_swap_size() {
  local value="$1"
  local amount
  case "${value}" in
    *[Mm])
      amount="${value%[Mm]}"
      ;;
    *[Gg])
      amount="${value%[Gg]}"
      ;;
    *)
      echo "SWAP_SIZE must use an M or G suffix, for example 2048M or 2G" >&2
      exit 1
      ;;
  esac

  if [[ ! "${amount}" =~ ^[0-9]+$ ]] || [ "${amount}" -lt 1 ]; then
    echo "SWAP_SIZE must use a positive integer with an M or G suffix" >&2
    exit 1
  fi

  case "${value}" in
    *[Mm]) SWAP_SIZE_MB="${amount}" ;;
    *[Gg]) SWAP_SIZE_MB=$((amount * 1024)) ;;
  esac
}

install_base_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gzip tar openssl rsync
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl gzip tar openssl rsync
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl gzip tar openssl rsync
    return
  fi

  echo "Unsupported Linux distribution: apt-get/dnf/yum not found" >&2
  exit 1
}

docker_compose_ready() {
  command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

start_docker() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  elif command -v service >/dev/null 2>&1; then
    service docker start || true
  elif command -v dockerd >/dev/null 2>&1 && ! pgrep -x dockerd >/dev/null 2>&1; then
    dockerd >/tmp/dockerd-bootstrap.log 2>&1 &
  fi
}

wait_for_docker() {
  local i
  i=1
  while [ "${i}" -le 30 ]; do
    if docker info >/dev/null 2>&1; then
      return
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "Docker daemon did not become ready" >&2
  if [ -f /tmp/dockerd-bootstrap.log ]; then
    tail -n 80 /tmp/dockerd-bootstrap.log >&2 || true
  fi
  exit 1
}

install_docker_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker.io docker-compose-plugin
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y docker docker-compose-plugin
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    yum install -y docker docker-compose-plugin
    return
  fi

  return 1
}

install_docker_get_script() {
  local installer
  installer="/tmp/get-docker-$(date -u +%Y%m%dT%H%M%SZ)-$$.sh"
  curl -fsSL https://get.docker.com -o "${installer}"
  sh "${installer}"
  rm -f "${installer}"
}

install_docker() {
  case "${DOCKER_INSTALL_METHOD}" in
    auto|package|get-docker) ;;
    *)
      echo "DOCKER_INSTALL_METHOD must be auto, package, or get-docker" >&2
      exit 1
      ;;
  esac

  if docker_compose_ready; then
    start_docker
    wait_for_docker
    docker --version
    docker compose version
    return
  fi

  if [ "${DOCKER_INSTALL_METHOD}" = package ] || [ "${DOCKER_INSTALL_METHOD}" = auto ]; then
    if install_docker_packages; then
      start_docker
      if docker_compose_ready; then
        wait_for_docker
        docker --version
        docker compose version
        return
      fi
      echo "Package Docker install did not provide docker compose plugin" >&2
    elif [ "${DOCKER_INSTALL_METHOD}" = package ]; then
      echo "Docker package install failed or package manager is unsupported" >&2
      exit 1
    fi
  fi

  if [ "${DOCKER_INSTALL_METHOD}" = get-docker ] || [ "${DOCKER_INSTALL_METHOD}" = auto ]; then
    install_docker_get_script
    start_docker
    wait_for_docker
  fi

  if ! docker_compose_ready; then
    echo "Docker Compose plugin is not available after Docker install" >&2
    docker --version >&2 || true
    exit 1
  fi

  docker --version
  docker compose version
}

ensure_swap() {
  if swapon --show=NAME --noheadings | grep -q .; then
    return
  fi

  if [ -f /swapfile ]; then
    chmod 600 /swapfile
    swapon /swapfile || true
  fi

  if ! swapon --show=NAME --noheadings | grep -q .; then
    fallocate -l "${SWAP_SIZE}" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}"
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
  fi

  if ! grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi
}

open_firewall_ports() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --permanent --add-service=https || true
    firewall-cmd --reload || true
  fi
}

prepare_dirs() {
  mkdir -p \
    "${REMOTE_DIR}/data" \
    "${REMOTE_DIR}/postgres_data" \
    "${REMOTE_DIR}/redis_data" \
    "${REMOTE_DIR}/caddy_data" \
    "${REMOTE_DIR}/caddy_config" \
    "${REMOTE_DIR}/logs/caddy"
}

need_root
parse_swap_size "${SWAP_SIZE}"
install_base_packages
install_docker
ensure_swap
open_firewall_ports
prepare_dirs

echo "Bootstrap complete: ${REMOTE_DIR}"
