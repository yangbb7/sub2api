#!/usr/bin/env bash
set -euo pipefail

CLI_SSH_TARGET_SET=false
CLI_SSH_PORT_SET=false
CLI_SSH_KEY_SET=false
CLI_SSH_PASSWORD_ENV_SET=false
CLI_SSH_PASS_ENV_SET=false
CLI_SSH_PASSWORD_SET=false
[ "${SSH_TARGET+x}" = x ] && CLI_SSH_TARGET_SET=true
[ "${SSH_PORT+x}" = x ] && CLI_SSH_PORT_SET=true
[ "${SSH_KEY+x}" = x ] && CLI_SSH_KEY_SET=true
[ "${SSH_PASSWORD+x}" = x ] && CLI_SSH_PASSWORD_ENV_SET=true
[ "${SSH_PASS+x}" = x ] && CLI_SSH_PASS_ENV_SET=true
if [ "${CLI_SSH_PASSWORD_ENV_SET}" = true ] || [ "${CLI_SSH_PASS_ENV_SET}" = true ]; then
  CLI_SSH_PASSWORD_SET=true
fi

load_env_file() {
  local env_file="$1"
  local restore_commands=""
  local name
  for name in \
    TARGET_REGION \
    SSH_TARGET SSH_PORT SSH_KEY SSH_PASSWORD SSH_PASS SSH_CONNECT_TIMEOUT REMOTE_DIR BACKUP_FILE RESTART REMOTE_SUDO SUDO_PASSWORD \
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
REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
BACKUP_FILE="${BACKUP_FILE:-}"
RESTART="${RESTART:-true}"

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

region_password_value() {
  local prefix="$1"
  local password
  local pass
  password="$(eval "printf '%s' \"\${${prefix}_SSH_PASSWORD:-}\"")"
  pass="$(eval "printf '%s' \"\${${prefix}_SSH_PASS:-}\"")"
  if [ -n "${password}" ] && [ -n "${pass}" ] && [ "${password}" != "${pass}" ]; then
    echo "${prefix}_SSH_PASSWORD and ${prefix}_SSH_PASS must not differ" >&2
    exit 1
  fi
  printf '%s' "${password:-${pass}}"
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

apply_target_region() {
  local region="$1"
  local prefix
  local value
  prefix="$(region_prefix "${region}")"
  TARGET_REGION="${region}"

  value="$(region_value "${prefix}" SSH_TARGET)"
  [ -n "${value}" ] && [ "${CLI_SSH_TARGET_SET}" != true ] && SSH_TARGET="${value}"
  value="$(region_value "${prefix}" SSH_PORT)"
  [ -n "${value}" ] && [ "${CLI_SSH_PORT_SET}" != true ] && SSH_PORT="${value}"
  value="$(region_value "${prefix}" SSH_KEY)"
  [ -n "${value}" ] && [ "${CLI_SSH_KEY_SET}" != true ] && SSH_KEY="${value}"
  value="$(region_password_value "${prefix}")"
  [ -n "${value}" ] && [ "${CLI_SSH_PASSWORD_SET}" != true ] && SSH_PASSWORD="${value}"
  return 0
}

try_region_restore_target() {
  local region="$1"
  local prefix
  local candidate_target
  local candidate_port
  local candidate_key
  local candidate_password
  local args=()

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
    return 1
  fi
  if [ -n "${candidate_key}" ] && [ -n "${candidate_password}" ]; then
    echo "Skipping TARGET_REGION=${region}: use exactly one SSH auth method: ${prefix}_SSH_KEY, ${prefix}_SSH_PASSWORD, or ${prefix}_SSH_PASS" >&2
    return 1
  fi
  if [ -n "${candidate_key}" ] && [ ! -f "${candidate_key}" ]; then
    echo "Skipping TARGET_REGION=${region}: ${prefix}_SSH_KEY does not exist: ${candidate_key}" >&2
    return 1
  fi
  if [ -n "${candidate_port}" ]; then
    validate_port "${prefix}_SSH_PORT" "${candidate_port}"
    args+=(-p "${candidate_port}")
  fi
  if [ -n "${candidate_key}" ]; then
    args+=(-i "${candidate_key}")
  fi
  args+=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
    -o ConnectionAttempts=1
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=2
  )

  echo "Trying TARGET_REGION=${region} restore target..."
  if [ -n "${candidate_password}" ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "Skipping TARGET_REGION=${region}: sshpass is required for password auth" >&2
      return 1
    fi
    SSHPASS="${candidate_password}" sshpass -e ssh "${args[@]}" "${candidate_target}" "test -f '${REMOTE_DIR}/docker-compose.1g.yml'"
  else
    ssh "${args[@]}" "${candidate_target}" "test -f '${REMOTE_DIR}/docker-compose.1g.yml'"
  fi
}

auto_select_target_region() {
  local region
  for region in jp hk; do
    if try_region_restore_target "${region}"; then
      apply_target_region "${region}"
      echo "Selected TARGET_REGION=${region}: ${SSH_TARGET}"
      return 0
    fi
    echo "TARGET_REGION=${region} is not a restore target" >&2
  done
  echo "No TARGET_REGION=auto candidate has ${REMOTE_DIR}/docker-compose.1g.yml" >&2
  exit 1
}

select_target_region() {
  case "${TARGET_REGION}" in
    "") return ;;
    auto) auto_select_target_region ;;
    jp|japan|hk|hongkong) apply_target_region "${TARGET_REGION}" ;;
    *)
      echo "TARGET_REGION must be auto, jp, hk, or empty" >&2
      exit 1
      ;;
  esac
}

normalize_ssh_password_alias
select_target_region

if [ -z "${SSH_TARGET}" ]; then
  cat >&2 <<'EOF'
Required environment:
  ENV_FILE=deploy/deploy-1g.env.local  # optional
  SSH_TARGET=root@server_ip

Optional:
  SSH_PORT=22
  SSH_KEY=/path/to/key
  SSH_PASSWORD=password
  SSH_PASS=password
  REMOTE_DIR=/opt/gateway
  BACKUP_FILE=backups/config-YYYYMMDDTHHMMSSZ.tar.gz  # default: latest
  RESTART=true
EOF
  exit 1
fi

validate_bool RESTART "${RESTART}"
validate_remote_sudo
if [ -n "${SSH_PORT}" ]; then
  validate_port SSH_PORT "${SSH_PORT}"
fi
validate_seconds SSH_CONNECT_TIMEOUT "${SSH_CONNECT_TIMEOUT}"

if [[ ! "${REMOTE_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "REMOTE_DIR must be an absolute path containing only letters, numbers, dot, dash, underscore, and slash" >&2
  exit 1
fi

if [ -n "${BACKUP_FILE}" ] && [[ ! "${BACKUP_FILE}" =~ ^backups/config-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]; then
  echo "BACKUP_FILE must look like backups/config-YYYYMMDDTHHMMSSZ.tar.gz" >&2
  exit 1
fi

validate_selected_ssh_auth

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need ssh
if [ -n "${SSH_PASSWORD}" ]; then
  need sshpass
fi

SSH_ARGS=()
SCP_ARGS=()
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
    remote_sudo_askpass="/tmp/gateway-restore-sudo-askpass-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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

detect_remote_root_method
run_remote_root "set -eu; cd '${REMOTE_DIR}'; backup='${BACKUP_FILE}'; if [ -z \"\$backup\" ]; then backup=\$(ls -1t backups/config-*.tar.gz 2>/dev/null | head -1 || true); fi; if [ -z \"\$backup\" ]; then echo 'No config backup found' >&2; exit 1; fi; test -f \"\$backup\"; echo \"Restoring \$backup\"; tar -xzf \"\$backup\"; docker compose --env-file .env -f docker-compose.1g.yml config >/dev/null; if [ '${RESTART}' = true ]; then docker compose --env-file .env -f docker-compose.1g.yml up -d; fi; echo \"Restore complete: \$backup\""
