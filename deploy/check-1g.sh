#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SCRIPT="${SCRIPT_DIR}/probe-frontend.sh"

CLI_SSH_TARGET_SET=false
CLI_SSH_PORT_SET=false
CLI_SSH_KEY_SET=false
CLI_SSH_PASSWORD_ENV_SET=false
CLI_SSH_PASS_ENV_SET=false
CLI_SSH_PASSWORD_SET=false
CLI_TARGET_IP_SET=false
[ "${SSH_TARGET+x}" = x ] && CLI_SSH_TARGET_SET=true
[ "${SSH_PORT+x}" = x ] && CLI_SSH_PORT_SET=true
[ "${SSH_KEY+x}" = x ] && CLI_SSH_KEY_SET=true
[ "${SSH_PASSWORD+x}" = x ] && CLI_SSH_PASSWORD_ENV_SET=true
[ "${SSH_PASS+x}" = x ] && CLI_SSH_PASS_ENV_SET=true
if [ "${CLI_SSH_PASSWORD_ENV_SET}" = true ] || [ "${CLI_SSH_PASS_ENV_SET}" = true ]; then
  CLI_SSH_PASSWORD_SET=true
fi
[ "${TARGET_IP+x}" = x ] && CLI_TARGET_IP_SET=true
AUTO_REMOTE_CHECK_DONE=false

load_env_file() {
  local env_file="$1"
  local restore_commands=""
  local name
  for name in \
    TARGET_REGION \
    SSH_TARGET SSH_PORT SSH_KEY SSH_PASSWORD SSH_PASS SSH_CONNECT_TIMEOUT DOMAIN TARGET_IP REMOTE_DIR PROXIED REMOTE_SUDO SUDO_PASSWORD \
    JP_SSH_TARGET JP_SSH_PORT JP_SSH_KEY JP_SSH_PASSWORD JP_SSH_PASS JP_TARGET_IP \
    HK_SSH_TARGET HK_SSH_PORT HK_SSH_KEY HK_SSH_PASSWORD HK_SSH_PASS HK_TARGET_IP
  do
    if [ "${!name+x}" = x ]; then
      restore_commands+="$(printf 'export %s=%q;' "${name}" "${!name}")"
    fi
  done
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
  # Command-line environment variables win over ENV_FILE values.
  eval "${restore_commands}"
}

ENV_FILE="${ENV_FILE:-}"
if [ -n "${ENV_FILE}" ]; then
  if [ ! -f "${ENV_FILE}" ]; then
    echo "ENV_FILE does not exist: ${ENV_FILE}" >&2
    exit 1
  fi
  load_env_file "${ENV_FILE}"
fi

SSH_TARGET="${SSH_TARGET:-}"
SSH_PORT="${SSH_PORT:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_PASS="${SSH_PASS:-}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
REMOTE_SUDO="${REMOTE_SUDO:-auto}"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"
TARGET_REGION="${TARGET_REGION:-}"
DOMAIN="${DOMAIN:-}"
TARGET_IP="${TARGET_IP:-}"
REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
PROXIED="${PROXIED:-false}"

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

validate_remote_sudo() {
  case "${REMOTE_SUDO}" in
    auto|true|false) ;;
    *)
      echo "REMOTE_SUDO must be auto, true, or false" >&2
      exit 1
      ;;
  esac
}

single_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
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

validate_port() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${#value}" -gt 5 ] || [ "$((10#${value}))" -lt 1 ] || [ "$((10#${value}))" -gt 65535 ]; then
    echo "${name} must be an integer from 1 to 65535" >&2
    exit 1
  fi
}

validate_seconds() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${#value}" -gt 3 ] || [ "$((10#${value}))" -lt 1 ] || [ "$((10#${value}))" -gt 300 ]; then
    echo "${name} must be an integer from 1 to 300" >&2
    exit 1
  fi
}

validate_selected_ssh_auth() {
  if [ -n "${SSH_KEY}" ] && [ -n "${SSH_PASSWORD}" ]; then
    echo "Use exactly one SSH auth method: SSH_KEY or SSH_PASSWORD/SSH_PASS, not both" >&2
    exit 1
  fi
  if [ -n "${SSH_KEY}" ] && [ ! -f "${SSH_KEY}" ]; then
    echo "SSH_KEY does not exist: ${SSH_KEY}" >&2
    exit 1
  fi
}

normalize_ssh_password_alias() {
  if [ "${CLI_SSH_PASS_ENV_SET}" = true ]; then
    if [ "${CLI_SSH_PASSWORD_ENV_SET}" = true ] && [ "${SSH_PASSWORD}" != "${SSH_PASS}" ]; then
      echo "SSH_PASSWORD and SSH_PASS must not differ" >&2
      exit 1
    fi
    SSH_PASSWORD="${SSH_PASS}"
    return
  fi
  if [ -z "${SSH_PASSWORD}" ]; then
    SSH_PASSWORD="${SSH_PASS}"
    return
  fi
  if [ -n "${SSH_PASS}" ] && [ "${SSH_PASSWORD}" != "${SSH_PASS}" ] && [ "${CLI_SSH_PASSWORD_ENV_SET}" != true ]; then
    echo "SSH_PASSWORD and SSH_PASS must not differ" >&2
    exit 1
  fi
}

region_prefix() {
  case "$1" in
    jp|japan) printf 'JP' ;;
    hk|hongkong) printf 'HK' ;;
    *)
      echo "TARGET_REGION must be auto, jp, hk, or empty" >&2
      exit 1
      ;;
  esac
}

region_value() {
  local prefix="$1"
  local suffix="$2"
  local name="${prefix}_${suffix}"
  printf '%s' "${!name:-}"
}

region_password_value() {
  local prefix="$1"
  local password
  local pass
  password="$(region_value "${prefix}" SSH_PASSWORD)"
  pass="$(region_value "${prefix}" SSH_PASS)"
  if [ -n "${password}" ] && [ -n "${pass}" ] && [ "${password}" != "${pass}" ]; then
    echo "${prefix}_SSH_PASSWORD and ${prefix}_SSH_PASS must not differ" >&2
    exit 1
  fi
  printf '%s' "${password:-${pass}}"
}

apply_target_region() {
  local region="$1"
  local prefix
  local value
  prefix="$(region_prefix "${region}")"
  TARGET_REGION="${region}"

  value="$(region_value "${prefix}" SSH_TARGET)"
  [ -n "${value}" ] && [ "${CLI_SSH_TARGET_SET}" != true ] && SSH_TARGET="${value}"
  value="$(region_value "${prefix}" TARGET_IP)"
  [ -n "${value}" ] && [ "${CLI_TARGET_IP_SET}" != true ] && TARGET_IP="${value}"
  value="$(region_value "${prefix}" SSH_PORT)"
  [ -n "${value}" ] && [ "${CLI_SSH_PORT_SET}" != true ] && SSH_PORT="${value}"
  value="$(region_value "${prefix}" SSH_KEY)"
  [ -n "${value}" ] && [ "${CLI_SSH_KEY_SET}" != true ] && SSH_KEY="${value}"
  value="$(region_password_value "${prefix}")"
  [ -n "${value}" ] && [ "${CLI_SSH_PASSWORD_SET}" != true ] && SSH_PASSWORD="${value}"
  return 0
}

select_target_region() {
  case "${TARGET_REGION}" in
    ""|auto) return 0 ;;
    jp|japan|hk|hongkong) apply_target_region "${TARGET_REGION}" ;;
    *)
      echo "TARGET_REGION must be auto, jp, hk, or empty" >&2
      exit 1
      ;;
  esac
}

infer_target_ip() {
  local host_part
  if [ -z "${TARGET_IP}" ]; then
    host_part="${SSH_TARGET##*@}"
    host_part="${host_part%%:*}"
    if [[ "${host_part}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      TARGET_IP="${host_part}"
    fi
  fi
}

run_candidate_ssh() {
  local target="$1"
  local port="$2"
  local key="$3"
  local password="$4"
  shift 4
  local args=()

  if [ -n "${port}" ]; then
    args+=(-p "${port}")
  fi
  if [ -n "${key}" ]; then
    args+=(-i "${key}")
  fi
  args+=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
    -o ConnectionAttempts=1
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=2
  )

  if [ -n "${password}" ]; then
    SSHPASS="${password}" sshpass -e ssh "${args[@]}" "${target}" "$@"
  else
    ssh "${args[@]}" "${target}" "$@"
  fi
}

auto_select_target_region() {
  local region
  local prefix
  local candidate_target
  local candidate_port
  local candidate_key
  local candidate_password
  for region in jp hk; do
    prefix="$(region_prefix "${region}")"
    candidate_target="$(region_value "${prefix}" SSH_TARGET)"
    candidate_port="$(region_value "${prefix}" SSH_PORT)"
    candidate_key="$(region_value "${prefix}" SSH_KEY)"
    candidate_password="$(region_password_value "${prefix}")"
    if [ -z "${candidate_port}" ] && [ "${CLI_SSH_PORT_SET}" = true ]; then
      candidate_port="${SSH_PORT}"
    fi
    if [ -z "${candidate_key}" ] && [ "${CLI_SSH_KEY_SET}" = true ]; then
      candidate_key="${SSH_KEY}"
    fi
    if [ -z "${candidate_password}" ] && [ "${CLI_SSH_PASSWORD_SET}" = true ]; then
      candidate_password="${SSH_PASSWORD}"
    fi

    if [ -z "${candidate_target}" ]; then
      echo "Skipping TARGET_REGION=${region}: ${prefix}_SSH_TARGET is empty" >&2
      continue
    fi
    if [ -n "${candidate_key}" ] && [ -n "${candidate_password}" ]; then
      echo "TARGET_REGION=${region} failed remote health: use exactly one SSH auth method: ${prefix}_SSH_KEY, ${prefix}_SSH_PASSWORD, or ${prefix}_SSH_PASS" >&2
      continue
    fi
    if [ -n "${candidate_key}" ] && [ ! -f "${candidate_key}" ]; then
      echo "TARGET_REGION=${region} failed remote health: ${prefix}_SSH_KEY does not exist: ${candidate_key}" >&2
      continue
    fi
    if [ -n "${candidate_port}" ]; then
      validate_port "${prefix}_SSH_PORT" "${candidate_port}"
    fi
    if [ -n "${candidate_password}" ]; then
      need sshpass
    fi

    echo "Trying TARGET_REGION=${region} remote health..."
    if run_candidate_ssh "${candidate_target}" "${candidate_port}" "${candidate_key}" "${candidate_password}" \
      "curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:18080/health >/dev/null && curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:18080/login >/dev/null && df -h '${REMOTE_DIR}' && (free -m || true)"; then
      apply_target_region "${region}"
      infer_target_ip
      AUTO_REMOTE_CHECK_DONE=false
      echo "Selected TARGET_REGION=${region}: ${SSH_TARGET}"
      return 0
    fi
    echo "TARGET_REGION=${region} failed remote health" >&2
  done

  echo "No TARGET_REGION=auto candidate passed remote health" >&2
  exit 1
}

normalize_ssh_password_alias
select_target_region

if { [ "${TARGET_REGION}" != auto ] && [ -z "${SSH_TARGET}" ]; } || [ -z "${DOMAIN}" ]; then
  cat >&2 <<'EOF'
Required environment:
  ENV_FILE=deploy/deploy-1g.env.local  # optional
  SSH_TARGET=root@server_ip
  DOMAIN=api.example.com

Optional:
  SSH_PORT=22
  SSH_KEY=/path/to/key
  SSH_PASSWORD=password
  SSH_PASS=password
  TARGET_IP=server_public_ip
  REMOTE_DIR=/opt/gateway
  PROXIED=false
EOF
  exit 1
fi

validate_bool PROXIED "${PROXIED}"
validate_remote_sudo
if [ -n "${SSH_PORT}" ]; then
  validate_port SSH_PORT "${SSH_PORT}"
fi
validate_seconds SSH_CONNECT_TIMEOUT "${SSH_CONNECT_TIMEOUT}"

validate_domain DOMAIN "${DOMAIN}"

if [[ ! "${REMOTE_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "REMOTE_DIR must be an absolute path containing only letters, numbers, dot, dash, underscore, and slash" >&2
  exit 1
fi

if [ "${TARGET_REGION}" != auto ]; then
  infer_target_ip
fi

if [ "${TARGET_REGION}" != auto ] && [ -n "${TARGET_IP}" ]; then
  validate_ipv4 TARGET_IP "${TARGET_IP}"
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need curl
need python3
need ssh

if [ "${TARGET_REGION}" = auto ]; then
  auto_select_target_region
  if [ -n "${TARGET_IP}" ]; then
    validate_ipv4 TARGET_IP "${TARGET_IP}"
  fi
fi

validate_selected_ssh_auth

SSH_ARGS=()
SCP_ARGS=()
if [ -n "${SSH_PASSWORD}" ]; then
  need sshpass
fi
if [ -n "${SSH_PORT}" ]; then
  SSH_ARGS+=(-p "${SSH_PORT}")
  SCP_ARGS+=(-P "${SSH_PORT}")
fi
if [ -n "${SSH_KEY}" ]; then
  SSH_ARGS+=(-i "${SSH_KEY}")
  SCP_ARGS+=(-i "${SSH_KEY}")
fi
SSH_ARGS+=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
  -o ConnectionAttempts=2
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)
SCP_ARGS+=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
  -o ConnectionAttempts=2
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)

run_ssh() {
  if [ -n "${SSH_PASSWORD}" ]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_ARGS[@]}" "$@"
  else
    ssh "${SSH_ARGS[@]}" "$@"
  fi
}

remote_root_method=""
remote_sudo_askpass=""
run_remote_root() {
  local command="$1"
  local quoted_command
  local quoted_askpass
  if [ "${remote_root_method}" = root ]; then
    run_ssh "${SSH_TARGET}" "${command}"
    return
  fi
  quoted_command="$(single_quote "${command}")"
  if [ -n "${remote_sudo_askpass}" ]; then
    quoted_askpass="$(single_quote "${remote_sudo_askpass}")"
    run_ssh "${SSH_TARGET}" "SUDO_ASKPASS=${quoted_askpass} sudo -A bash -lc ${quoted_command}"
  else
    run_ssh "${SSH_TARGET}" "sudo -n bash -lc ${quoted_command}"
  fi
}

detect_remote_root_method() {
  local uid
  local local_askpass
  local quoted_askpass
  uid="$(run_ssh "${SSH_TARGET}" "id -u")"
  if [ "${uid}" = 0 ]; then
    remote_root_method=root
    return
  fi
  if [ "${REMOTE_SUDO}" = false ]; then
    echo "Remote SSH user is uid ${uid}, but REMOTE_SUDO=false" >&2
    exit 1
  fi
  if ! run_ssh "${SSH_TARGET}" "command -v sudo >/dev/null 2>&1"; then
    echo "Remote SSH user is not root and sudo is not installed" >&2
    exit 1
  fi
  SUDO_PASSWORD="${SUDO_PASSWORD:-${SSH_PASSWORD}}"
  if [ -n "${SUDO_PASSWORD}" ]; then
    local_askpass="$(mktemp)"
    {
      printf '#!/bin/sh\n'
      printf 'printf '"'"'%%s\\n'"'"' %s\n' "$(single_quote "${SUDO_PASSWORD}")"
    } > "${local_askpass}"
    chmod 700 "${local_askpass}"
    remote_sudo_askpass="/tmp/gateway-check-sudo-askpass-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    if [ -n "${SSH_PASSWORD}" ]; then
      SSHPASS="${SSH_PASSWORD}" sshpass -e scp "${SCP_ARGS[@]}" "${local_askpass}" "${SSH_TARGET}:${remote_sudo_askpass}"
    else
      scp "${SCP_ARGS[@]}" "${local_askpass}" "${SSH_TARGET}:${remote_sudo_askpass}"
    fi
    rm -f "${local_askpass}"
    run_ssh "${SSH_TARGET}" "chmod 700 '${remote_sudo_askpass}'"
    quoted_askpass="$(single_quote "${remote_sudo_askpass}")"
    run_ssh "${SSH_TARGET}" "SUDO_ASKPASS=${quoted_askpass} sudo -A -v"
  else
    run_ssh "${SSH_TARGET}" "sudo -n -v"
  fi
  remote_root_method=sudo
}

cleanup_remote_askpass() {
  if [ -n "${remote_sudo_askpass}" ]; then
    run_ssh "${SSH_TARGET}" "rm -f '${remote_sudo_askpass}'" >/dev/null 2>&1 || true
  fi
}
trap cleanup_remote_askpass EXIT

if [ "${AUTO_REMOTE_CHECK_DONE}" = true ]; then
  echo "Remote services already checked: ${SSH_TARGET}"
else
  echo "Checking remote services..."
  detect_remote_root_method
  run_remote_root "cd '${REMOTE_DIR}' && docker compose --env-file .env -f docker-compose.1g.yml ps && df -h '${REMOTE_DIR}' && (free -m || true)"
  run_ssh "${SSH_TARGET}" "BASE_URL='http://127.0.0.1:18080' ATTEMPTS=1 CONNECT_TIMEOUT=2 MAX_TIME=5 sh -s" < "${PROBE_SCRIPT}"
fi

echo "Checking DNS..."
resolved_ip="$(DOMAIN="${DOMAIN}" python3 -c 'import os, socket; print(socket.gethostbyname(os.environ["DOMAIN"]))')"
echo "${DOMAIN} resolves to ${resolved_ip}"
if [ "${PROXIED}" != "true" ] && [ -n "${TARGET_IP}" ] && [ "${resolved_ip}" != "${TARGET_IP}" ]; then
  echo "DNS mismatch: expected ${TARGET_IP}, got ${resolved_ip}" >&2
  exit 1
fi

if [ -n "${TARGET_IP}" ]; then
  echo "Checking public origin HTTP reachability..."
  curl -fsS --connect-timeout 5 --max-time 20 --resolve "${DOMAIN}:80:${TARGET_IP}" "http://${DOMAIN}/health" >/dev/null
fi

echo "Checking HTTPS health and login page..."
if [ "${PROXIED}" = true ] || [ -z "${TARGET_IP}" ]; then
  BASE_URL="https://${DOMAIN}" ATTEMPTS=1 CONNECT_TIMEOUT=5 MAX_TIME=20 "${PROBE_SCRIPT}"
else
  BASE_URL="https://${DOMAIN}" CURL_RESOLVE="${DOMAIN}:443:${TARGET_IP}" ATTEMPTS=1 CONNECT_TIMEOUT=5 MAX_TIME=20 "${PROBE_SCRIPT}"
fi

echo "1G deployment check passed: https://${DOMAIN}/health, /login, and frontend assets"
