#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"

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

load_env_file() {
  local env_file="$1"
  local restore_commands=""
  local name
  for name in \
    TARGET_REGION \
    SSH_TARGET SSH_PORT SSH_KEY SSH_PASSWORD SSH_PASS SSH_BIND_ADDRESS DOMAIN TARGET_IP REMOTE_DIR \
    JP_SSH_TARGET JP_SSH_PORT JP_SSH_KEY JP_SSH_PASSWORD JP_SSH_PASS JP_TARGET_IP \
    HK_SSH_TARGET HK_SSH_PORT HK_SSH_KEY HK_SSH_PASSWORD HK_SSH_PASS HK_TARGET_IP \
    PLATFORM GATEWAY_IMAGE ADMIN_EMAIL ADMIN_PASSWORD PROXIED DEPLOY_MODE BUILD_STRATEGY REMOTE_DOCKERFILE REMOTE_SUDO SUDO_PASSWORD \
    SKIP_DNS ROLLBACK_ON_FAILURE CF_API_TOKEN CF_ZONE_ID TTL TZ ACME_EMAIL UPDATE_PROXY_URL SSH_CONNECT_TIMEOUT \
    SWAP_SIZE MIN_FREE_KB MIN_DOCKER_FREE_KB DOCKER_INSTALL_METHOD BUILD_NODE_OPTIONS BUILD_GOMAXPROCS PNPM_REGISTRY \
    LOCAL_BUILD_GOMAXPROCS LOCAL_BUILD_GOMEMLIMIT LOCAL_BUILD_GCFLAGS SOURCE_UPLOAD_RETRIES SOURCE_UPLOAD_IDLE_TIMEOUT SOURCE_UPLOAD_DEADLINE SOURCE_UPLOAD_CHUNK_BYTES SOURCE_UPLOAD_PART_PAUSE_SECONDS \
    POSTGRES_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY REDIS_PASSWORD
  do
    if [ "${!name+x}" = x ]; then
      restore_commands+="$(printf 'export %s=%q;' "${name}" "${!name}")"
    fi
  done
  # shellcheck disable=SC1090
  set -a
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
SSH_BIND_ADDRESS="${SSH_BIND_ADDRESS:-}"
REMOTE_SUDO="${REMOTE_SUDO:-auto}"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"
TARGET_REGION="${TARGET_REGION:-}"
DOMAIN="${DOMAIN:-}"
TARGET_IP="${TARGET_IP:-}"
REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
PLATFORM="${PLATFORM:-linux/amd64}"
IMAGE_NAME="${GATEWAY_IMAGE:-gateway:cloud}"
BUILD_STRATEGY="${BUILD_STRATEGY:-local-binary}"
BUILD_NODE_OPTIONS="${BUILD_NODE_OPTIONS:---max-old-space-size=1280}"
BUILD_GOMAXPROCS="${BUILD_GOMAXPROCS:-1}"
PNPM_REGISTRY="${PNPM_REGISTRY:-https://registry.npmjs.org/}"
LOCAL_BUILD_GOMAXPROCS="${LOCAL_BUILD_GOMAXPROCS:-4}"
LOCAL_BUILD_GOMEMLIMIT="${LOCAL_BUILD_GOMEMLIMIT:-4GiB}"
LOCAL_BUILD_GCFLAGS="${LOCAL_BUILD_GCFLAGS:-}"
SOURCE_UPLOAD_RETRIES="${SOURCE_UPLOAD_RETRIES:-3}"
SOURCE_UPLOAD_IDLE_TIMEOUT="${SOURCE_UPLOAD_IDLE_TIMEOUT:-120}"
SOURCE_UPLOAD_DEADLINE="${SOURCE_UPLOAD_DEADLINE:-1800}"
# Some low-cost VPS routes reset a long-running SCP/rsync stream after a few
# MiB. Upload deterministic small parts and assemble only after checksum
# verification, so a retry resumes the affected part instead of the archive.
SOURCE_UPLOAD_CHUNK_BYTES="${SOURCE_UPLOAD_CHUNK_BYTES:-1048576}"
# A small pause prevents macOS clients with a narrow ephemeral-port range from
# accumulating hundreds of TIME_WAIT sockets while uploading many parts.
SOURCE_UPLOAD_PART_PAUSE_SECONDS="${SOURCE_UPLOAD_PART_PAUSE_SECONDS:-3}"
BUILD_COMMIT="${BUILD_COMMIT:-$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD 2>/dev/null || printf 'archive')}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
if [ -z "${REMOTE_DOCKERFILE:-}" ]; then
  case "${BUILD_STRATEGY}" in
    local-binary) REMOTE_DOCKERFILE=deploy/Dockerfile.binary ;;
    remote) REMOTE_DOCKERFILE=deploy/Dockerfile.prebuilt ;;
    *) REMOTE_DOCKERFILE=deploy/Dockerfile.binary ;;
  esac
fi
SWAP_SIZE="${SWAP_SIZE:-2G}"
MIN_FREE_KB="${MIN_FREE_KB:-3145728}"
MIN_DOCKER_FREE_KB="${MIN_DOCKER_FREE_KB:-4194304}"
DOCKER_INSTALL_METHOD="${DOCKER_INSTALL_METHOD:-auto}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@gateway.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
PROXIED="${PROXIED:-false}"
DEPLOY_MODE="${DEPLOY_MODE:-deploy}"
SKIP_DNS="${SKIP_DNS:-false}"
ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-true}"
TTL="${TTL:-1}"
PREFLIGHT_ALREADY_DONE=false

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

validate_build_strategy() {
  case "${BUILD_STRATEGY}" in
    local-binary|remote) ;;
    *)
      echo "BUILD_STRATEGY must be local-binary or remote" >&2
      exit 1
      ;;
  esac
}

validate_docker_install_method() {
  case "${DOCKER_INSTALL_METHOD}" in
    auto|package|get-docker) ;;
    *)
      echo "DOCKER_INSTALL_METHOD must be auto, package, or get-docker" >&2
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

validate_positive_kb() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -lt 1 ]; then
    echo "${name} must be a positive integer in KB" >&2
    exit 1
  fi
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -lt 1 ]; then
    echo "${name} must be a positive integer" >&2
    exit 1
  fi
}

validate_swap_size() {
  local value="$1"
  local amount
  case "${value}" in
    *[Mm]|*[Gg])
      amount="${value%[MmGg]}"
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
}

validate_env_token() {
  local name="$1"
  local value="$2"
  local pattern='^[A-Za-z0-9._@:/+=,?&%-]+$'
  if [ -z "${value}" ]; then
    return
  fi
  if [[ ! "${value}" =~ ${pattern} ]]; then
    echo "${name} contains characters that cannot be written safely to the remote .env" >&2
    exit 1
  fi
}

validate_optional_email() {
  local name="$1"
  local value="$2"
  if [ -z "${value}" ]; then
    return
  fi
  if [[ ! "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "${name} must be a valid email address" >&2
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
  if [ -n "${SSH_TARGET}" ] && [ -z "${TARGET_IP}" ]; then
    host_part="${SSH_TARGET##*@}"
    host_part="${host_part%%:*}"
    if [[ "${host_part}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      TARGET_IP="${host_part}"
    fi
  fi
}

run_region_preflight() {
  local region="$1"
  local prefix
  local candidate_target
  local candidate_port
  local candidate_key
  local candidate_password
  local candidate_sudo_password
  local candidate_args=()
  local candidate_scp_args=()
  local preflight_tmp_dir
  local remote_script
  local remote_askpass=""
  local local_askpass
  local quoted_askpass
  local uid
  local command

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
    candidate_args+=(-p "${candidate_port}")
    candidate_scp_args+=(-P "${candidate_port}")
  fi
  if [ -n "${candidate_key}" ]; then
    candidate_args+=(-i "${candidate_key}")
    candidate_scp_args+=(-i "${candidate_key}")
  fi
  candidate_args+=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
    -o ConnectionAttempts=1
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=2
  )
  candidate_scp_args+=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
    -o ConnectionAttempts=1
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=2
  )

  preflight_tmp_dir="$(mktemp -d)"
  remote_script="/tmp/gateway-root-script-auto-$(date -u +%Y%m%dT%H%M%SZ)-$$-${region}.sh"
  cleanup_region_preflight() {
    rm -rf "${preflight_tmp_dir}"
    if [ -n "${candidate_password}" ]; then
      SSHPASS="${candidate_password}" sshpass -e ssh "${candidate_args[@]}" "${candidate_target}" "rm -f '${remote_script}' '${remote_askpass}'" >/dev/null 2>&1 || true
    else
      ssh "${candidate_args[@]}" "${candidate_target}" "rm -f '${remote_script}' '${remote_askpass}'" >/dev/null 2>&1 || true
    fi
  }

  if [ -n "${candidate_password}" ]; then
    need sshpass
    uid="$(SSHPASS="${candidate_password}" sshpass -e ssh "${candidate_args[@]}" "${candidate_target}" "id -u")" || {
      cleanup_region_preflight
      return 1
    }
    SSHPASS="${candidate_password}" sshpass -e scp "${candidate_scp_args[@]}" "${DEPLOY_DIR}/remote-1g-preflight.sh" "${candidate_target}:${remote_script}" || {
      cleanup_region_preflight
      return 1
    }
  else
    uid="$(ssh "${candidate_args[@]}" "${candidate_target}" "id -u")" || {
      cleanup_region_preflight
      return 1
    }
    scp "${candidate_scp_args[@]}" "${DEPLOY_DIR}/remote-1g-preflight.sh" "${candidate_target}:${remote_script}" || {
      cleanup_region_preflight
      return 1
    }
  fi
  command="REMOTE_DIR='${REMOTE_DIR}' EXPECTED_PLATFORM='${PLATFORM}' MIN_FREE_KB='${MIN_FREE_KB}' MIN_DOCKER_FREE_KB='${MIN_DOCKER_FREE_KB}' sh '${remote_script}'"
  if [ "${uid}" != 0 ]; then
    if [ "${REMOTE_SUDO}" = false ]; then
      echo "Skipping TARGET_REGION=${region}: SSH user is uid ${uid}, but REMOTE_SUDO=false" >&2
      cleanup_region_preflight
      return 1
    fi
    candidate_sudo_password="${SUDO_PASSWORD:-${candidate_password}}"
    if [ -n "${candidate_sudo_password}" ]; then
      local_askpass="${preflight_tmp_dir}/sudo-askpass.sh"
      {
        printf '#!/bin/sh\n'
        printf 'printf '"'"'%%s\\n'"'"' %s\n' "$(single_quote "${candidate_sudo_password}")"
      } > "${local_askpass}"
      chmod 700 "${local_askpass}"
      remote_askpass="/tmp/gateway-sudo-askpass-auto-$(date -u +%Y%m%dT%H%M%SZ)-$$-${region}"
      if [ -n "${candidate_password}" ]; then
        SSHPASS="${candidate_password}" sshpass -e scp "${candidate_scp_args[@]}" "${local_askpass}" "${candidate_target}:${remote_askpass}" || {
          cleanup_region_preflight
          return 1
        }
        SSHPASS="${candidate_password}" sshpass -e ssh "${candidate_args[@]}" "${candidate_target}" "chmod 700 '${remote_askpass}'" || {
          cleanup_region_preflight
          return 1
        }
      else
        scp "${candidate_scp_args[@]}" "${local_askpass}" "${candidate_target}:${remote_askpass}" || {
          cleanup_region_preflight
          return 1
        }
        ssh "${candidate_args[@]}" "${candidate_target}" "chmod 700 '${remote_askpass}'" || {
          cleanup_region_preflight
          return 1
        }
      fi
      quoted_askpass="$(single_quote "${remote_askpass}")"
      command="SUDO_ASKPASS=${quoted_askpass} sudo -A bash -lc $(single_quote "${command}")"
    else
      command="sudo -n bash -lc $(single_quote "${command}")"
    fi
  fi
  if [ -n "${candidate_password}" ]; then
    SSHPASS="${candidate_password}" sshpass -e ssh "${candidate_args[@]}" "${candidate_target}" "${command}" || {
      cleanup_region_preflight
      return 1
    }
  else
    ssh "${candidate_args[@]}" "${candidate_target}" "${command}" || {
      cleanup_region_preflight
      return 1
    }
  fi
  cleanup_region_preflight
}

auto_select_target_region() {
  local region
  for region in jp hk; do
    echo "Trying TARGET_REGION=${region} remote preflight..."
    if run_region_preflight "${region}"; then
      apply_target_region "${region}"
      infer_target_ip
      PREFLIGHT_ALREADY_DONE=true
      echo "Selected TARGET_REGION=${region}: ${SSH_TARGET}"
      return 0
    fi
    echo "TARGET_REGION=${region} failed remote preflight" >&2
  done

  echo "No TARGET_REGION=auto candidate passed remote preflight" >&2
  exit 1
}

case "${DEPLOY_MODE}" in
  build|preflight|deploy) ;;
  *)
    echo "DEPLOY_MODE must be build, preflight, or deploy" >&2
    exit 1
    ;;
esac

normalize_ssh_password_alias
select_target_region

if { [ "${TARGET_REGION}" != auto ] && [ -z "${SSH_TARGET}" ]; } ||
  { [ "${DEPLOY_MODE}" = deploy ] && [ -z "${DOMAIN}" ]; }; then
  cat >&2 <<'EOF'
Required environment:
  ENV_FILE=deploy/deploy-1g.env.local  # optional
  DEPLOY_MODE=deploy          # deploy, preflight, or build on the VPS
  SSH_TARGET=root@server_ip
  SSH_PORT=22                 # optional
  SSH_KEY=/path/to/key        # optional
  SSH_PASSWORD=password        # optional, requires sshpass
  SSH_PASS=password            # optional alias used by some local skills
  DOMAIN=api.example.com

Recommended:
  CF_API_TOKEN=<Cloudflare token with Zone:Read + DNS:Edit>
  TARGET_IP=<server public IPv4>  # auto-detected from SSH_TARGET when it is an IP

Optional:
  REMOTE_DIR=/opt/gateway
  PLATFORM=linux/amd64
  GATEWAY_IMAGE=gateway:cloud
  REMOTE_SUDO=auto           # root SSH runs directly; non-root SSH uses sudo
  SUDO_PASSWORD=password     # optional if sudo password differs from SSH password
  ADMIN_EMAIL=admin@example.com
  ADMIN_PASSWORD=<leave empty to let deploy script generate one>
  DOCKER_INSTALL_METHOD=auto # auto, package, or get-docker
  PROXIED=false
  SKIP_DNS=false
  TARGET_REGION=auto|jp|hk
EOF
  exit 1
fi

validate_bool SKIP_DNS "${SKIP_DNS}"
validate_bool PROXIED "${PROXIED}"
validate_bool ROLLBACK_ON_FAILURE "${ROLLBACK_ON_FAILURE}"
validate_ttl "${TTL}"
validate_proxied_ttl

case "${PLATFORM}" in
  linux/amd64|linux/arm64) ;;
  *)
    echo "PLATFORM must be linux/amd64 or linux/arm64" >&2
    exit 1
    ;;
esac

if [ -n "${SSH_PORT}" ]; then
  validate_port SSH_PORT "${SSH_PORT}"
fi

validate_seconds SSH_CONNECT_TIMEOUT "${SSH_CONNECT_TIMEOUT}"
validate_swap_size "${SWAP_SIZE}"
validate_positive_kb MIN_FREE_KB "${MIN_FREE_KB}"
validate_positive_kb MIN_DOCKER_FREE_KB "${MIN_DOCKER_FREE_KB}"

infer_target_ip

if [ "${DEPLOY_MODE}" = deploy ] && [ "${TARGET_REGION}" != auto ] && [ -z "${TARGET_IP}" ]; then
  echo "TARGET_IP is required when SSH_TARGET is not an IPv4 address" >&2
  exit 1
fi

if [ -n "${TARGET_IP}" ]; then
  validate_ipv4 TARGET_IP "${TARGET_IP}"
fi

if [ -n "${DOMAIN}" ]; then
  validate_domain DOMAIN "${DOMAIN}"
fi

if [[ ! "${REMOTE_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "REMOTE_DIR must be an absolute path containing only letters, numbers, dot, dash, underscore, and slash" >&2
  exit 1
fi

validate_env_token DOMAIN "${DOMAIN}"
validate_env_token GATEWAY_IMAGE "${IMAGE_NAME}"
validate_env_token BUILD_NODE_OPTIONS "${BUILD_NODE_OPTIONS}"
validate_env_token PNPM_REGISTRY "${PNPM_REGISTRY}"
validate_env_token ADMIN_EMAIL "${ADMIN_EMAIL}"
validate_optional_email ADMIN_EMAIL "${ADMIN_EMAIL}"
validate_env_token ADMIN_PASSWORD "${ADMIN_PASSWORD}"
validate_env_token ACME_EMAIL "${ACME_EMAIL:-}"
validate_optional_email ACME_EMAIL "${ACME_EMAIL:-}"
validate_env_token UPDATE_PROXY_URL "${UPDATE_PROXY_URL:-}"
validate_env_token POSTGRES_PASSWORD "${POSTGRES_PASSWORD:-}"
validate_env_token JWT_SECRET "${JWT_SECRET:-}"
validate_env_token TOTP_ENCRYPTION_KEY "${TOTP_ENCRYPTION_KEY:-}"
validate_env_token REDIS_PASSWORD "${REDIS_PASSWORD:-}"
validate_remote_sudo
validate_build_strategy
validate_docker_install_method
validate_positive_int BUILD_GOMAXPROCS "${BUILD_GOMAXPROCS}"
validate_positive_int LOCAL_BUILD_GOMAXPROCS "${LOCAL_BUILD_GOMAXPROCS}"
validate_positive_int SOURCE_UPLOAD_RETRIES "${SOURCE_UPLOAD_RETRIES}"
validate_positive_int SOURCE_UPLOAD_IDLE_TIMEOUT "${SOURCE_UPLOAD_IDLE_TIMEOUT}"
validate_positive_int SOURCE_UPLOAD_DEADLINE "${SOURCE_UPLOAD_DEADLINE}"
validate_positive_int SOURCE_UPLOAD_CHUNK_BYTES "${SOURCE_UPLOAD_CHUNK_BYTES}"
validate_positive_int SOURCE_UPLOAD_PART_PAUSE_SECONDS "${SOURCE_UPLOAD_PART_PAUSE_SECONDS}"
if [ -n "${SSH_BIND_ADDRESS}" ]; then
  validate_ipv4 SSH_BIND_ADDRESS "${SSH_BIND_ADDRESS}"
fi
validate_env_token LOCAL_BUILD_GOMEMLIMIT "${LOCAL_BUILD_GOMEMLIMIT}"
validate_env_token LOCAL_BUILD_GCFLAGS "${LOCAL_BUILD_GCFLAGS}"

if [ "${BUILD_STRATEGY}" = local-binary ]; then
  case "${PLATFORM}" in
    linux/amd64|linux/arm64) ;;
    *)
      echo "BUILD_STRATEGY=local-binary supports PLATFORM=linux/amd64 or linux/arm64" >&2
      exit 1
      ;;
  esac
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

rand_hex() {
  openssl rand -hex 32
}

rand_short_hex() {
  openssl rand -hex 16
}

verify_public_dns_points_to_target() {
  local resolved_ips
  local resolved_count

  resolved_ips="$(DOMAIN="${DOMAIN}" python3 - <<'PY'
import os
import socket
import sys

domain = os.environ["DOMAIN"]
try:
    infos = socket.getaddrinfo(domain, 80, socket.AF_INET, socket.SOCK_STREAM)
except OSError as exc:
    print(f"DNS lookup failed for {domain}: {exc}", file=sys.stderr)
    sys.exit(1)

ips = sorted({item[4][0] for item in infos})
if not ips:
    print(f"DNS lookup returned no A records for {domain}", file=sys.stderr)
    sys.exit(1)
print("\n".join(ips))
PY
)"
  resolved_count="$(printf '%s\n' "${resolved_ips}" | awk 'NF {count++} END {print count + 0}')"
  echo "Public DNS A record(s) for ${DOMAIN}:"
  printf '%s\n' "${resolved_ips}" | sed 's/^/  /'

  if [ "${resolved_count}" -ne 1 ] || [ "${resolved_ips}" != "${TARGET_IP}" ]; then
    echo "SKIP_DNS=true with PROXIED=false requires public DNS to resolve only to ${TARGET_IP} before deploy." >&2
    echo "Actual A record(s):" >&2
    printf '%s\n' "${resolved_ips}" | sed 's/^/  /' >&2
    echo "Fix Cloudflare DNS first, or set SKIP_DNS=false and provide CF_API_TOKEN so the deploy script can update it." >&2
    exit 1
  fi
}

case "${DEPLOY_MODE}" in
  build)
    need ssh
    need scp
    need rsync
    need perl
    need tar
    need gzip
    need split
    need openssl
    if [ "${BUILD_STRATEGY}" = local-binary ]; then
      need git
      need go
      need pnpm
    fi
    ;;
  preflight)
    need ssh
    ;;
  deploy)
    need ssh
    need scp
    need curl
    need gzip
    need tar
    need openssl
    need split
    if [ "${BUILD_STRATEGY}" = local-binary ]; then
      need git
      need go
      need pnpm
    fi
    if [ "${SKIP_DNS}" = true ] && [ "${PROXIED}" != true ]; then
      need python3
    fi
    if [ "${SKIP_DNS}" != true ]; then
      if [ -z "${CF_API_TOKEN:-}" ]; then
        echo "CF_API_TOKEN is required for deploy mode unless SKIP_DNS=true" >&2
        exit 1
      fi
      need python3
    fi
    ;;
esac

if [ "${TARGET_REGION}" = auto ]; then
  auto_select_target_region
  if [ "${DEPLOY_MODE}" = deploy ] && [ -z "${TARGET_IP}" ]; then
    echo "TARGET_IP is required when the selected SSH target is not an IPv4 address" >&2
    exit 1
  fi
  if [ -n "${TARGET_IP}" ]; then
    validate_ipv4 TARGET_IP "${TARGET_IP}"
  fi
fi

validate_selected_ssh_auth

if [ "${DEPLOY_MODE}" = deploy ] && [ "${SKIP_DNS}" = true ] && [ "${PROXIED}" != true ]; then
  echo "Checking public DNS because SKIP_DNS=true and PROXIED=false..."
  verify_public_dns_points_to_target
fi

if [ "${DEPLOY_MODE}" = deploy ] && [ "${SKIP_DNS}" != true ]; then
  echo "Checking Cloudflare DNS write access..."
  CF_API_TOKEN="${CF_API_TOKEN}" DOMAIN="${DOMAIN}" TARGET_IP="${TARGET_IP}" PROXIED="${PROXIED}" TTL="${TTL:-1}" CF_ZONE_ID="${CF_ZONE_ID:-}" WRITE_CHECK_ONLY=true \
    "${DEPLOY_DIR}/cloudflare-upsert-dns.sh"
fi

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
if [ -n "${SSH_BIND_ADDRESS}" ]; then
  SSH_ARGS+=(-o "BindAddress=${SSH_BIND_ADDRESS}")
  SCP_ARGS+=(-o "BindAddress=${SSH_BIND_ADDRESS}")
fi

run_ssh() {
  if [ -n "${SSH_PASSWORD}" ]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_ARGS[@]}" "$@"
  else
    ssh "${SSH_ARGS[@]}" "$@"
  fi
}

run_scp() {
  if [ -n "${SSH_PASSWORD}" ]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e scp "${SCP_ARGS[@]}" "$@"
  else
    scp "${SCP_ARGS[@]}" "$@"
  fi
}

rsync_ssh_command() {
  local arg
  printf '%q' ssh
  for arg in "${SSH_ARGS[@]}"; do
    printf ' %q' "${arg}"
  done
}

run_rsync() {
  local ssh_command
  ssh_command="$(rsync_ssh_command)"
  if [ -n "${SSH_PASSWORD}" ]; then
    SSHPASS="${SSH_PASSWORD}" run_with_deadline "${SOURCE_UPLOAD_DEADLINE}" \
      sshpass -e rsync -e "${ssh_command}" "$@"
  else
    run_with_deadline "${SOURCE_UPLOAD_DEADLINE}" rsync -e "${ssh_command}" "$@"
  fi
}

run_with_deadline() {
  "${DEPLOY_DIR}/run-with-deadline.pl" "$@"
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

run_remote_root_script() {
  local script="$1"
  local interpreter="$2"
  local env_prefix="$3"
  local remote_script="/tmp/gateway-root-script-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(basename "${script}")"
  local status
  run_scp "${script}" "${SSH_TARGET}:${remote_script}"
  run_ssh "${SSH_TARGET}" "chmod 700 '${remote_script}'"
  status=0
  run_remote_root "${env_prefix} ${interpreter} '${remote_script}'" || status=$?
  run_ssh "${SSH_TARGET}" "rm -f '${remote_script}'" >/dev/null 2>&1 || true
  return "${status}"
}

detect_remote_root_method() {
  local uid
  local local_askpass
  local quoted_askpass
  uid="$(run_ssh "${SSH_TARGET}" "id -u")"
  if [ "${uid}" = 0 ]; then
    remote_root_method=root
    echo "Remote privilege: root SSH"
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
    local_askpass="${tmp_dir}/sudo-askpass.sh"
    {
      printf '#!/bin/sh\n'
      printf 'printf '"'"'%%s\\n'"'"' %s\n' "$(single_quote "${SUDO_PASSWORD}")"
    } > "${local_askpass}"
    chmod 700 "${local_askpass}"
    remote_sudo_askpass="/tmp/gateway-sudo-askpass-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    run_scp "${local_askpass}" "${SSH_TARGET}:${remote_sudo_askpass}"
    run_ssh "${SSH_TARGET}" "chmod 700 '${remote_sudo_askpass}'"
    quoted_askpass="$(single_quote "${remote_sudo_askpass}")"
    if ! run_ssh "${SSH_TARGET}" "SUDO_ASKPASS=${quoted_askpass} sudo -A -v"; then
      echo "sudo validation failed for ${SSH_TARGET}; set SUDO_PASSWORD if it differs from SSH_PASSWORD, or use root SSH" >&2
      exit 1
    fi
  elif ! run_ssh "${SSH_TARGET}" "sudo -n -v"; then
    echo "Remote SSH user is not root and passwordless sudo is not available; set SUDO_PASSWORD or use root SSH" >&2
    exit 1
  fi
  remote_root_method=sudo
  echo "Remote privilege: sudo via ${SSH_TARGET%%@*}"
}

collect_remote_diagnostics() {
  run_remote_root "cd '${REMOTE_DIR}' && {
    echo '--- compose ps ---'
    docker compose --env-file .env -f docker-compose.1g.yml ps || true
    echo '--- docker stats ---'
    docker stats --no-stream gateway gateway-caddy gateway-postgres gateway-redis || true
    echo '--- caddy logs ---'
    docker compose --env-file .env -f docker-compose.1g.yml logs --no-color --tail=160 caddy || true
    echo '--- gateway logs ---'
    docker compose --env-file .env -f docker-compose.1g.yml logs --no-color --tail=160 gateway || true
    echo '--- postgres logs ---'
    docker compose --env-file .env -f docker-compose.1g.yml logs --no-color --tail=120 postgres || true
    echo '--- redis logs ---'
    docker compose --env-file .env -f docker-compose.1g.yml logs --no-color --tail=120 redis || true
    echo '--- disk ---'
    df -h '${REMOTE_DIR}' /var/lib/docker 2>/dev/null || df -h '${REMOTE_DIR}' || true
    echo '--- memory ---'
    free -m || true
    echo '--- listening ports ---'
    { ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true; } | grep -E '(:80|:443|:18080)[[:space:]]' || true
  }" || true
}

ensure_clean_git_tree_for_local_binary() {
  local status_output
  status_output="$(git -C "${ROOT_DIR}" status --short --untracked-files=normal)"
  if [ -n "${status_output}" ]; then
    echo "BUILD_STRATEGY=local-binary requires a clean git worktree so the deployed binary matches HEAD." >&2
    printf '%s\n' "${status_output}" >&2
    echo "Commit or remove these changes before deploying." >&2
    exit 1
  fi
}

create_source_archive() {
  echo "Creating build context for ${BUILD_STRATEGY} image..."
  local archive_dir="${tmp_dir}/source"
  local target_goos
  local target_goarch
  local go_build_args
  rm -rf "${archive_dir}"
  mkdir -p "${archive_dir}"

  if [ "${BUILD_STRATEGY}" = local-binary ]; then
    ensure_clean_git_tree_for_local_binary
    mkdir -p "${archive_dir}/build" "${archive_dir}/deploy"
    cp "${DEPLOY_DIR}/Dockerfile.binary" "${archive_dir}/deploy/Dockerfile.binary"
    cp "${DEPLOY_DIR}/docker-entrypoint.sh" "${archive_dir}/deploy/docker-entrypoint.sh"
    target_goos="${PLATFORM%%/*}"
    target_goarch="${PLATFORM#*/}"
    echo "Building frontend locally for embedded binary..."
    (cd "${ROOT_DIR}/frontend" && VITE_DISABLE_CHECKER=true pnpm exec vite build --config vite.config.ts)
    test -f "${ROOT_DIR}/backend/internal/web/dist/index.html"
    echo "Building backend binary locally for ${PLATFORM}..."
    go_build_args=(
      -tags embed
      -ldflags "-s -w -X main.Version=docker -X main.Commit=${BUILD_COMMIT} -X main.Date=${BUILD_DATE} -X main.BuildType=release"
      -o "${archive_dir}/build/gateway"
    )
    if [ -n "${LOCAL_BUILD_GCFLAGS}" ]; then
      go_build_args=(-gcflags "${LOCAL_BUILD_GCFLAGS}" "${go_build_args[@]}")
    fi
    (cd "${ROOT_DIR}/backend" && CGO_ENABLED=0 GOOS="${target_goos}" GOARCH="${target_goarch}" GOMAXPROCS="${LOCAL_BUILD_GOMAXPROCS}" GOMEMLIMIT="${LOCAL_BUILD_GOMEMLIMIT}" GOGC=50 go build "${go_build_args[@]}" ./cmd/server)
  else
    git -C "${ROOT_DIR}" archive --format=tar HEAD | tar -x -C "${archive_dir}"
    if [ "${REMOTE_DOCKERFILE}" = "deploy/Dockerfile.prebuilt" ]; then
      echo "Building frontend locally for prebuilt remote image..."
      (cd "${ROOT_DIR}/frontend" && VITE_DISABLE_CHECKER=true pnpm exec vite build --config vite.config.ts)
      test -f "${ROOT_DIR}/backend/internal/web/dist/index.html"
      rm -rf "${archive_dir}/backend/internal/web/dist"
      mkdir -p "${archive_dir}/backend/internal/web"
      cp -R "${ROOT_DIR}/backend/internal/web/dist" "${archive_dir}/backend/internal/web/dist"
    fi
  fi
  tar -czf "${tmp_dir}/source.tar.gz" -C "${archive_dir}" .
}

remote_build_image() {
  echo "Building ${IMAGE_NAME} on remote host..."
  run_remote_root "set -eu; echo '--- remote memory before build ---'; free -m || true; rm -rf '${remote_upload_dir}/src'; mkdir -p '${remote_upload_dir}/src'; tar -xzf '${remote_upload_dir}/source.tar.gz' -C '${remote_upload_dir}/src'; cd '${remote_upload_dir}/src'; DOCKER_BUILDKIT=0 docker build --build-arg NODE_OPTIONS='${BUILD_NODE_OPTIONS}' --build-arg BUILD_GOMAXPROCS='${BUILD_GOMAXPROCS}' --build-arg PNPM_REGISTRY='${PNPM_REGISTRY}' --build-arg COMMIT='${BUILD_COMMIT}' --build-arg DATE='${BUILD_DATE}' -f '${REMOTE_DOCKERFILE}' -t '${IMAGE_NAME}' .; cd /; rm -rf '${remote_upload_dir}/src' '${remote_upload_dir}/source.tar.gz'; docker image prune -f >/dev/null || true"
}

sha256_file() {
  openssl dgst -sha256 -r "$1" | awk '{print $1}'
}

upload_source_part() {
  local part="$1"
  local destination="$2"
  local attempt

  for ((attempt = 1; attempt <= SOURCE_UPLOAD_RETRIES; attempt++)); do
    # macOS ships an older rsync without --append-verify. SSH supplies
    # transport integrity and the archive-level SHA-256 below verifies the
    # final assembled bytes, while --append keeps the fixed part resumable.
    if run_rsync --append --timeout="${SOURCE_UPLOAD_IDLE_TIMEOUT}" "${part}" "${destination}"; then
      return 0
    fi
    if [ "${attempt}" -lt "${SOURCE_UPLOAD_RETRIES}" ]; then
      echo "Source part upload interrupted; resuming part $(basename "${part}") (attempt $((attempt + 1))/${SOURCE_UPLOAD_RETRIES})..." >&2
      sleep 3
    fi
  done

  echo "Source part upload failed after ${SOURCE_UPLOAD_RETRIES} attempt(s): $(basename "${part}")" >&2
  return 1
}

upload_source_archive() {
  local archive="$1"
  local remote_archive="$2"
  local local_parts_dir="${tmp_dir}/source-parts"
  local remote_parts_dir="${remote_archive}.parts"
  local remote_assembling="${remote_archive}.assembling"
  local part part_name checksum remote_command

  rm -rf "${local_parts_dir}"
  mkdir -p "${local_parts_dir}"
  split -b "${SOURCE_UPLOAD_CHUNK_BYTES}" -d -a 6 "${archive}" "${local_parts_dir}/part-"
  checksum="$(sha256_file "${archive}")"
  [ -n "${checksum}" ] || {
    echo "Could not calculate source archive checksum." >&2
    return 1
  }

  run_ssh "${SSH_TARGET}" "mkdir -p $(single_quote "${remote_parts_dir}") && rm -f $(single_quote "${remote_assembling}")"
  for part in "${local_parts_dir}"/part-*; do
    [ -f "${part}" ] || continue
    part_name="$(basename "${part}")"
    echo "Uploading source archive part ${part_name}..."
    upload_source_part "${part}" "${SSH_TARGET}:${remote_parts_dir}/${part_name}"
    sleep "${SOURCE_UPLOAD_PART_PAUSE_SECONDS}"
  done

  remote_command="set -eu; cat $(single_quote "${remote_parts_dir}")/part-* > $(single_quote "${remote_assembling}"); actual=\$(openssl dgst -sha256 -r $(single_quote "${remote_assembling}") | awk '{print \$1}'); test \"\${actual}\" = $(single_quote "${checksum}"); mv $(single_quote "${remote_assembling}") $(single_quote "${remote_archive}"); rm -rf $(single_quote "${remote_parts_dir}")"
  run_ssh "${SSH_TARGET}" "${remote_command}"
  echo "Source archive uploaded and checksum verified in ${remote_archive}."
}

remote_validate_caddyfile() {
  echo "Validating Caddyfile on remote host..."
  run_remote_root "docker run --rm -e DOMAIN='${DOMAIN}' -v '${remote_upload_dir}/Caddyfile.1g:/etc/caddy/Caddyfile:ro' caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null"
}

tmp_dir="$(mktemp -d)"
remote_upload_dir=""
remote_upload_committed=false
remote_backup_file=""
live_files_installed=false
dns_updated=false
deployment_succeeded=false
cleanup() {
  local status=$?
  local will_rollback=false
  rm -rf "${tmp_dir}"
  if { [ "${DEPLOY_MODE:-}" = deploy ] || [ "${DEPLOY_MODE:-}" = build ]; } &&
    [ -n "${remote_upload_dir:-}" ] &&
    [ "${remote_upload_committed:-false}" != true ] &&
    [ -n "${SSH_TARGET:-}" ]; then
    run_ssh "${SSH_TARGET}" "rm -rf '${remote_upload_dir}'" >/dev/null 2>&1 || true
  fi
  if [ -n "${remote_sudo_askpass:-}" ] && [ -n "${SSH_TARGET:-}" ]; then
    run_ssh "${SSH_TARGET}" "rm -f '${remote_sudo_askpass}'" >/dev/null 2>&1 || true
  fi
  if [ "${status}" -ne 0 ] &&
    [ "${DEPLOY_MODE:-}" = deploy ] &&
    [ "${ROLLBACK_ON_FAILURE:-true}" = true ] &&
    [ "${deployment_succeeded:-false}" != true ] &&
    [ "${live_files_installed:-false}" = true ] &&
    [ "${dns_updated:-false}" != true ] &&
    [ -n "${remote_backup_file:-}" ]; then
    will_rollback=true
    echo "Deployment failed before DNS cutover; attempting remote config rollback to ${remote_backup_file}" >&2
    run_remote_root "set -eu; cd '${REMOTE_DIR}'; backup='${remote_backup_file}'; test -f \"\$backup\"; tar -xzf \"\$backup\"; docker compose --env-file .env -f docker-compose.1g.yml config >/dev/null; docker compose --env-file .env -f docker-compose.1g.yml up -d; echo \"Rolled back to \$backup\"" >&2 || true
  fi
  if [ "${status}" -ne 0 ] &&
    [ "${DEPLOY_MODE:-}" = deploy ] &&
    [ "${GENERATED_ADMIN_PASSWORD:-false}" = true ] &&
    [ "${live_files_installed:-false}" = true ] &&
    [ "${will_rollback}" != true ]; then
    echo "Generated admin credentials were written to ${REMOTE_DIR}/.env on ${SSH_TARGET}:" >&2
    echo "  ADMIN_EMAIL=${ADMIN_EMAIL}" >&2
    echo "  ADMIN_PASSWORD=${ADMIN_PASSWORD}" >&2
  fi
  return "${status}"
}
trap cleanup EXIT
remote_upload_dir="/tmp/gateway-deploy-upload-$(date -u +%Y%m%dT%H%M%SZ)-$$"

if [ "${DEPLOY_MODE}" = build ]; then
  detect_remote_root_method
  echo "Bootstrapping remote host for remote build..."
  run_remote_root_script "${DEPLOY_DIR}/remote-1g-bootstrap.sh" bash "REMOTE_DIR='${REMOTE_DIR}' SWAP_SIZE='${SWAP_SIZE}' DOCKER_INSTALL_METHOD='${DOCKER_INSTALL_METHOD}'"
  create_source_archive
  run_ssh "${SSH_TARGET}" "rm -rf '${remote_upload_dir}' && mkdir -p '${remote_upload_dir}'"
  upload_source_archive "${tmp_dir}/source.tar.gz" "${remote_upload_dir}/source.tar.gz"
  remote_build_image
  run_ssh "${SSH_TARGET}" "rm -rf '${remote_upload_dir}'" >/dev/null 2>&1 || true
  remote_upload_committed=true
  echo "Remote build complete: ${IMAGE_NAME} on ${SSH_TARGET}"
  exit 0
fi

detect_remote_root_method

if [ "${PREFLIGHT_ALREADY_DONE}" = true ]; then
  echo "Remote preflight already passed: ${SSH_TARGET}"
else
  echo "Running remote preflight..."
  run_remote_root_script "${DEPLOY_DIR}/remote-1g-preflight.sh" sh "REMOTE_DIR='${REMOTE_DIR}' EXPECTED_PLATFORM='${PLATFORM}' MIN_FREE_KB='${MIN_FREE_KB}' MIN_DOCKER_FREE_KB='${MIN_DOCKER_FREE_KB}'"
fi

if [ "${DEPLOY_MODE}" = preflight ]; then
  echo "Remote preflight complete: ${SSH_TARGET}"
  exit 0
fi

create_source_archive

POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(rand_hex)}"
JWT_SECRET="${JWT_SECRET:-$(rand_hex)}"
TOTP_ENCRYPTION_KEY="${TOTP_ENCRYPTION_KEY:-$(rand_hex)}"
GENERATED_ADMIN_PASSWORD=false
if [ -z "${ADMIN_PASSWORD}" ]; then
  ADMIN_PASSWORD="$(rand_short_hex)"
  GENERATED_ADMIN_PASSWORD=true
fi

cat > "${tmp_dir}/.env" <<EOF
DOMAIN=${DOMAIN}
GATEWAY_IMAGE=${IMAGE_NAME}
ACME_EMAIL=${ACME_EMAIL:-}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
TZ=${TZ:-Asia/Shanghai}
GOMAXPROCS=1
GOMEMLIMIT=192MiB
DATABASE_MAX_OPEN_CONNS=8
DATABASE_MAX_IDLE_CONNS=2
POSTGRES_MAX_CONNECTIONS=30
POSTGRES_SHARED_BUFFERS=48MB
POSTGRES_EFFECTIVE_CACHE_SIZE=192MB
POSTGRES_MAINTENANCE_WORK_MEM=24MB
POSTGRES_WORK_MEM=1MB
REDIS_POOL_SIZE=16
REDIS_MIN_IDLE_CONNS=1
REDIS_MAXMEMORY=64mb
REDIS_MAXCLIENTS=96
REDIS_PASSWORD=${REDIS_PASSWORD:-}
SERVER_MAX_REQUEST_BODY_SIZE=104857600
GATEWAY_MAX_BODY_SIZE=104857600
LOG_ROTATION_MAX_SIZE_MB=10
LOG_ROTATION_MAX_BACKUPS=3
LOG_ROTATION_MAX_AGE_DAYS=7
UPDATE_PROXY_URL=${UPDATE_PROXY_URL:-}
EOF
chmod 600 "${tmp_dir}/.env"

if [ -n "${ACME_EMAIL:-}" ]; then
  {
    printf '{\n\temail %s\n}\n\n' "${ACME_EMAIL}"
    cat "${DEPLOY_DIR}/Caddyfile.1g"
  } > "${tmp_dir}/Caddyfile.1g"
else
  cp "${DEPLOY_DIR}/Caddyfile.1g" "${tmp_dir}/Caddyfile.1g"
fi

echo "Bootstrapping remote host..."
run_remote_root_script "${DEPLOY_DIR}/remote-1g-bootstrap.sh" bash "REMOTE_DIR='${REMOTE_DIR}' SWAP_SIZE='${SWAP_SIZE}' DOCKER_INSTALL_METHOD='${DOCKER_INSTALL_METHOD}'"

echo "Backing up existing remote config..."
remote_backup_file="$(run_remote_root "set -eu; mkdir -p '${REMOTE_DIR}/backups'; cd '${REMOTE_DIR}'; files=''; for file in .env docker-compose.1g.yml Caddyfile.1g; do if [ -f \"\$file\" ]; then files=\"\$files \$file\"; fi; done; if [ -n \"\$files\" ]; then backup=\"backups/config-\$(date -u +%Y%m%dT%H%M%SZ).tar.gz\"; tar -czf \"\$backup\" \$files; printf '%s\n' \"\$backup\"; fi")"
if [ -n "${remote_backup_file}" ]; then
  echo "Saved ${remote_backup_file}"
else
  echo "No existing config to back up"
fi

echo "Uploading deployment files..."
run_ssh "${SSH_TARGET}" "rm -rf '${remote_upload_dir}' && mkdir -p '${remote_upload_dir}'"
upload_files=(
  "${DEPLOY_DIR}/docker-compose.1g.yml"
  "${tmp_dir}/Caddyfile.1g"
  "${tmp_dir}/.env"
  "${tmp_dir}/source.tar.gz"
)
run_scp "${upload_files[@]}" "${SSH_TARGET}:${remote_upload_dir}/"
run_ssh "${SSH_TARGET}" "cd '${remote_upload_dir}' && chmod 600 .env"

remote_validate_caddyfile

remote_build_image

echo "Validating remote compose config..."
run_remote_root "cd '${remote_upload_dir}' && docker compose --env-file .env -f docker-compose.1g.yml config >/dev/null"

echo "Pulling runtime images on remote host..."
run_remote_root "cd '${remote_upload_dir}' && docker compose --env-file .env -f docker-compose.1g.yml pull caddy postgres redis"

echo "Installing deployment files..."
run_remote_root "set -eu; cd '${REMOTE_DIR}'; mv '${remote_upload_dir}/docker-compose.1g.yml' docker-compose.1g.yml; mv '${remote_upload_dir}/Caddyfile.1g' Caddyfile.1g; mv '${remote_upload_dir}/.env' .env; rm -rf '${remote_upload_dir}'"
remote_upload_committed=true
live_files_installed=true

echo "Starting services..."
run_remote_root "cd '${REMOTE_DIR}' && docker compose --env-file .env -f docker-compose.1g.yml up -d postgres redis && docker compose --env-file .env -f docker-compose.1g.yml up -d --force-recreate gateway caddy && { docker image prune -f >/dev/null || true; }"

echo "Waiting for local gateway health, login page, and frontend assets on remote..."
if ! run_ssh "${SSH_TARGET}" "BASE_URL='http://127.0.0.1:18080' ATTEMPTS=60 SLEEP_SECONDS=2 CONNECT_TIMEOUT=2 MAX_TIME=5 sh -s" < "${DEPLOY_DIR}/probe-frontend.sh"; then
  collect_remote_diagnostics
  exit 1
fi

echo "Checking public origin HTTP reachability..."
if ! curl -fsS --connect-timeout 5 --max-time 20 --resolve "${DOMAIN}:80:${TARGET_IP}" "http://${DOMAIN}/health" >/dev/null; then
  echo "Origin HTTP check failed: http://${DOMAIN}/health via ${TARGET_IP}:80" >&2
  echo "Open TCP 80 in the Huana Cloud security group/firewall before changing DNS." >&2
  exit 1
fi

if [ "${SKIP_DNS}" = true ]; then
  echo "Skipping Cloudflare DNS update because SKIP_DNS=true"
elif [ -n "${CF_API_TOKEN:-}" ]; then
  echo "Updating Cloudflare DNS..."
  CF_API_TOKEN="${CF_API_TOKEN}" DOMAIN="${DOMAIN}" TARGET_IP="${TARGET_IP}" PROXIED="${PROXIED}" TTL="${TTL:-1}" CF_ZONE_ID="${CF_ZONE_ID:-}" \
    "${DEPLOY_DIR}/cloudflare-upsert-dns.sh"
  dns_updated=true
else
  echo "CF_API_TOKEN is required for deploy mode unless SKIP_DNS=true" >&2
  exit 1
fi

echo "Waiting for HTTPS health, login page, and frontend assets..."
if [ "${PROXIED}" = true ]; then
  if BASE_URL="https://${DOMAIN}" ATTEMPTS=60 SLEEP_SECONDS=5 CONNECT_TIMEOUT=5 MAX_TIME=20 \
    "${DEPLOY_DIR}/probe-frontend.sh"; then
    echo "Deployment complete: https://${DOMAIN}"
    if [ "${GENERATED_ADMIN_PASSWORD}" = true ]; then
      echo "Generated admin login: ${ADMIN_EMAIL}"
      echo "Generated admin password: ${ADMIN_PASSWORD}"
    fi
    deployment_succeeded=true
    exit 0
  fi
elif BASE_URL="https://${DOMAIN}" CURL_RESOLVE="${DOMAIN}:443:${TARGET_IP}" ATTEMPTS=60 SLEEP_SECONDS=5 CONNECT_TIMEOUT=5 MAX_TIME=20 \
  "${DEPLOY_DIR}/probe-frontend.sh"; then
  echo "Deployment complete: https://${DOMAIN}"
  if [ "${GENERATED_ADMIN_PASSWORD}" = true ]; then
    echo "Generated admin login: ${ADMIN_EMAIL}"
    echo "Generated admin password: ${ADMIN_PASSWORD}"
  fi
  deployment_succeeded=true
  exit 0
fi

echo "Gateway is running on the server, but HTTPS health did not pass yet."
echo "Collecting remote diagnostics..."
collect_remote_diagnostics
echo "Check DNS/port 80/443/Caddy logs manually if needed:"
echo "  ssh ${SSH_TARGET} \"cd ${REMOTE_DIR} && docker compose --env-file .env -f docker-compose.1g.yml logs caddy\""
exit 1
