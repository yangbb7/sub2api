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
    SSH_TARGET SSH_PORT SSH_KEY SSH_PASSWORD SSH_PASS DOMAIN TARGET_IP REMOTE_DIR \
    JP_SSH_TARGET JP_SSH_PORT JP_SSH_KEY JP_SSH_PASSWORD JP_SSH_PASS JP_TARGET_IP \
    HK_SSH_TARGET HK_SSH_PORT HK_SSH_KEY HK_SSH_PASSWORD HK_SSH_PASS HK_TARGET_IP \
    PLATFORM GATEWAY_IMAGE ADMIN_EMAIL ADMIN_PASSWORD PROXIED SKIP_DNS BUILD_STRATEGY REMOTE_SUDO SUDO_PASSWORD \
    ROLLBACK_ON_FAILURE CF_API_TOKEN CF_ZONE_ID TTL TZ ACME_EMAIL UPDATE_PROXY_URL SSH_CONNECT_TIMEOUT \
    SWAP_SIZE MIN_FREE_KB MIN_DOCKER_FREE_KB DOCKER_INSTALL_METHOD BUILD_NODE_OPTIONS BUILD_GOMAXPROCS \
    POSTGRES_PASSWORD JWT_SECRET TOTP_ENCRYPTION_KEY REDIS_PASSWORD
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
PLATFORM="${PLATFORM:-linux/amd64}"
IMAGE_NAME="${GATEWAY_IMAGE:-gateway:cloud}"
BUILD_STRATEGY="${BUILD_STRATEGY:-remote}"
BUILD_NODE_OPTIONS="${BUILD_NODE_OPTIONS:---max-old-space-size=384}"
BUILD_GOMAXPROCS="${BUILD_GOMAXPROCS:-1}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
MIN_FREE_KB="${MIN_FREE_KB:-3145728}"
MIN_DOCKER_FREE_KB="${MIN_DOCKER_FREE_KB:-4194304}"
DOCKER_INSTALL_METHOD="${DOCKER_INSTALL_METHOD:-auto}"
PROXIED="${PROXIED:-false}"
SKIP_DNS="${SKIP_DNS:-false}"
ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-true}"
TTL="${TTL:-1}"

failures=0
warnings=0
AUTO_TARGET_UNAVAILABLE=false

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

warn() {
  echo "WARN: $*" >&2
  warnings=$((warnings + 1))
}

ok() {
  echo "OK: $*"
}

need() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "found $1"
  else
    fail "missing required command: $1"
  fi
}

validate_bool() {
  local name="$1"
  local value="$2"
  case "${value}" in
    true|false) ;;
    *) fail "${name} must be true or false" ;;
  esac
}

validate_remote_sudo() {
  case "${REMOTE_SUDO}" in
    auto|true|false) ;;
    *) fail "REMOTE_SUDO must be auto, true, or false" ;;
  esac
}

validate_build_strategy() {
  if [ "${BUILD_STRATEGY}" != remote ]; then
    fail "BUILD_STRATEGY=${BUILD_STRATEGY} is not supported by 1G cloud deployment; this profile always builds on the remote VPS"
  fi
}

validate_docker_install_method() {
  case "${DOCKER_INSTALL_METHOD}" in
    auto|package|get-docker) ;;
    *) fail "DOCKER_INSTALL_METHOD must be auto, package, or get-docker" ;;
  esac
}

validate_ipv4() {
  local name="$1"
  local value="$2"
  local first second third fourth
  local octet
  if [[ ! "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "${name} must be an IPv4 address"
    return
  fi
  IFS=. read -r first second third fourth <<< "${value}"
  for octet in "${first}" "${second}" "${third}" "${fourth}"; do
    if [ "${#octet}" -gt 3 ] || [ "$((10#${octet}))" -gt 255 ]; then
      fail "${name} must be an IPv4 address"
      return
    fi
  done
}

validate_domain() {
  local name="$1"
  local value="$2"
  local label
  local labels
  if [ -z "${value}" ] || [ "${#value}" -gt 253 ] || [[ "${value}" != *.* ]] || [[ "${value}" == .* || "${value}" == *. || "${value}" == *..* ]] || [[ ! "${value}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    fail "${name} must be a hostname with valid DNS labels, for example api.example.com"
    return
  fi
  IFS=. read -r -a labels <<< "${value}"
  for label in "${labels[@]}"; do
    if [ -z "${label}" ] || [ "${#label}" -gt 63 ] || [[ ! "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
      fail "${name} must be a hostname with valid DNS labels, for example api.example.com"
      return
    fi
  done
  label="${labels[$((${#labels[@]} - 1))]}"
  if [[ ! "${label}" =~ ^[A-Za-z]{2,63}$ ]]; then
    fail "${name} must use a valid alphabetic top-level domain, for example api.example.com"
  fi
}

validate_port() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${#value}" -gt 5 ] || [ "$((10#${value}))" -lt 1 ] || [ "$((10#${value}))" -gt 65535 ]; then
    fail "${name} must be an integer from 1 to 65535"
  fi
}

validate_ttl() {
  local value="$1"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    fail "TTL must be 1 for automatic or an integer from 60 to 86400"
    return
  fi
  if [ "${value}" -ne 1 ] && { [ "${value}" -lt 60 ] || [ "${value}" -gt 86400 ]; }; then
    fail "TTL must be 1 for automatic or an integer from 60 to 86400"
  fi
}

validate_proxied_ttl() {
  if [ "${PROXIED}" = true ] && [ "${TTL}" -ne 1 ]; then
    fail "TTL must be 1 when PROXIED=true because Cloudflare proxied records use automatic TTL"
  fi
}

validate_seconds() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${#value}" -gt 3 ] || [ "$((10#${value}))" -lt 1 ] || [ "$((10#${value}))" -gt 300 ]; then
    fail "${name} must be an integer from 1 to 300"
  fi
}

validate_positive_kb() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -lt 1 ]; then
    fail "${name} must be a positive integer in KB"
  fi
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]] || [ "${value}" -lt 1 ]; then
    fail "${name} must be a positive integer"
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
      fail "SWAP_SIZE must use an M or G suffix, for example 2048M or 2G"
      return
      ;;
  esac
  if [[ ! "${amount}" =~ ^[0-9]+$ ]] || [ "${amount}" -lt 1 ]; then
    fail "SWAP_SIZE must use a positive integer with an M or G suffix"
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
    fail "${name} contains characters that cannot be written safely to the remote .env"
  fi
}

validate_optional_email() {
  local name="$1"
  local value="$2"
  if [ -z "${value}" ]; then
    return
  fi
  if [[ ! "${value}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    fail "${name} must be a valid email address"
  fi
}

normalize_ssh_password_alias() {
  if [ "${CLI_SSH_PASS_ENV_SET}" = true ]; then
    if [ "${CLI_SSH_PASSWORD_ENV_SET}" = true ] && [ "${SSH_PASSWORD}" != "${SSH_PASS}" ]; then
      fail "SSH_PASSWORD and SSH_PASS must not differ"
      return
    fi
    SSH_PASSWORD="${SSH_PASS}"
    return
  fi
  if [ -z "${SSH_PASSWORD}" ]; then
    SSH_PASSWORD="${SSH_PASS}"
    return
  fi
  if [ -n "${SSH_PASS}" ] && [ "${SSH_PASSWORD}" != "${SSH_PASS}" ] && [ "${CLI_SSH_PASSWORD_ENV_SET}" != true ]; then
    fail "SSH_PASSWORD and SSH_PASS must not differ"
  fi
}

region_password_value() {
  local prefix="$1"
  local password
  local pass
  password="$(eval "printf '%s' \"\${${prefix}_SSH_PASSWORD:-}\"")"
  pass="$(eval "printf '%s' \"\${${prefix}_SSH_PASS:-}\"")"
  if [ -n "${password}" ] && [ -n "${pass}" ] && [ "${password}" != "${pass}" ]; then
    fail "${prefix}_SSH_PASSWORD and ${prefix}_SSH_PASS must not differ"
    printf ''
    return
  fi
  printf '%s' "${password:-${pass}}"
}

select_target_region() {
  local prefix=""
  local value
  case "${TARGET_REGION}" in
    "") return ;;
    auto)
      if [ -n "${JP_SSH_TARGET:-}" ]; then
        prefix="JP"
      elif [ -n "${HK_SSH_TARGET:-}" ]; then
        prefix="HK"
      else
        AUTO_TARGET_UNAVAILABLE=true
        fail "TARGET_REGION=auto requires JP_SSH_TARGET or HK_SSH_TARGET"
        return
      fi
      ;;
    jp|japan) prefix="JP" ;;
    hk|hongkong) prefix="HK" ;;
    *)
      fail "TARGET_REGION must be auto, jp, hk, or empty"
      return
      ;;
  esac

  value="$(eval "printf '%s' \"\${${prefix}_SSH_TARGET:-}\"")"
  [ -n "${value}" ] && [ "${CLI_SSH_TARGET_SET}" != true ] && SSH_TARGET="${value}"
  value="$(eval "printf '%s' \"\${${prefix}_TARGET_IP:-}\"")"
  [ -n "${value}" ] && [ "${CLI_TARGET_IP_SET}" != true ] && TARGET_IP="${value}"
  value="$(eval "printf '%s' \"\${${prefix}_SSH_PORT:-}\"")"
  [ -n "${value}" ] && [ "${CLI_SSH_PORT_SET}" != true ] && SSH_PORT="${value}"
  value="$(eval "printf '%s' \"\${${prefix}_SSH_KEY:-}\"")"
  [ -n "${value}" ] && [ "${CLI_SSH_KEY_SET}" != true ] && SSH_KEY="${value}"
  value="$(region_password_value "${prefix}")"
  [ -n "${value}" ] && [ "${CLI_SSH_PASSWORD_SET}" != true ] && SSH_PASSWORD="${value}"
  return 0
}

normalize_ssh_password_alias
select_target_region

if [ -n "${SSH_TARGET}" ] && [ -z "${TARGET_IP}" ]; then
  host_part="${SSH_TARGET##*@}"
  host_part="${host_part%%:*}"
  if [[ "${host_part}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    TARGET_IP="${host_part}"
  fi
fi

validate_bool SKIP_DNS "${SKIP_DNS}"
validate_bool PROXIED "${PROXIED}"
validate_bool ROLLBACK_ON_FAILURE "${ROLLBACK_ON_FAILURE}"
validate_remote_sudo
validate_build_strategy
validate_docker_install_method
validate_ttl "${TTL}"
validate_proxied_ttl

case "${PLATFORM}" in
  linux/amd64|linux/arm64) ;;
  *) fail "PLATFORM must be linux/amd64 or linux/arm64" ;;
esac

if [ -n "${SSH_PORT}" ]; then
  validate_port SSH_PORT "${SSH_PORT}"
fi
validate_seconds SSH_CONNECT_TIMEOUT "${SSH_CONNECT_TIMEOUT}"
validate_swap_size "${SWAP_SIZE}"
validate_positive_kb MIN_FREE_KB "${MIN_FREE_KB}"
validate_positive_kb MIN_DOCKER_FREE_KB "${MIN_DOCKER_FREE_KB}"
validate_positive_int BUILD_GOMAXPROCS "${BUILD_GOMAXPROCS}"

if [ "${AUTO_TARGET_UNAVAILABLE}" != true ] && [ -z "${SSH_TARGET}" ]; then
  fail "SSH_TARGET is required"
elif [ "${AUTO_TARGET_UNAVAILABLE}" != true ] && [ "${SSH_TARGET}" = "root@203.0.113.10" ]; then
  fail "SSH_TARGET is still the documentation placeholder"
fi

if [ -z "${DOMAIN}" ]; then
  fail "DOMAIN is required"
elif [ "${DOMAIN}" = "api.example.com" ]; then
  fail "DOMAIN is still the documentation placeholder"
else
  validate_domain DOMAIN "${DOMAIN}"
fi

if [ "${AUTO_TARGET_UNAVAILABLE}" != true ] && [ -z "${TARGET_IP}" ]; then
  fail "TARGET_IP is required when SSH_TARGET is not an IPv4 address"
elif [ "${AUTO_TARGET_UNAVAILABLE}" != true ]; then
  validate_ipv4 TARGET_IP "${TARGET_IP}"
  if [ "${TARGET_IP}" = "203.0.113.10" ]; then
    fail "TARGET_IP is still the documentation placeholder"
  fi
fi

if [[ ! "${REMOTE_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  fail "REMOTE_DIR must be an absolute path containing only letters, numbers, dot, dash, underscore, and slash"
fi

validate_env_token DOMAIN "${DOMAIN}"
validate_env_token GATEWAY_IMAGE "${IMAGE_NAME}"
validate_env_token BUILD_NODE_OPTIONS "${BUILD_NODE_OPTIONS}"
validate_env_token ADMIN_EMAIL "${ADMIN_EMAIL:-}"
validate_optional_email ADMIN_EMAIL "${ADMIN_EMAIL:-}"
validate_env_token ADMIN_PASSWORD "${ADMIN_PASSWORD:-}"
validate_env_token ACME_EMAIL "${ACME_EMAIL:-}"
validate_optional_email ACME_EMAIL "${ACME_EMAIL:-}"
validate_env_token UPDATE_PROXY_URL "${UPDATE_PROXY_URL:-}"
validate_env_token POSTGRES_PASSWORD "${POSTGRES_PASSWORD:-}"
validate_env_token JWT_SECRET "${JWT_SECRET:-}"
validate_env_token TOTP_ENCRYPTION_KEY "${TOTP_ENCRYPTION_KEY:-}"
validate_env_token REDIS_PASSWORD "${REDIS_PASSWORD:-}"

if [ "${SKIP_DNS}" != true ] && [ -z "${CF_API_TOKEN:-}" ]; then
  fail "CF_API_TOKEN is required unless SKIP_DNS=true"
fi

if [ -n "${SSH_KEY}" ] && [ -n "${SSH_PASSWORD}" ]; then
  fail "Use exactly one SSH auth method: SSH_KEY or SSH_PASSWORD/SSH_PASS, not both"
fi

if [ -n "${SSH_KEY}" ] && [ ! -f "${SSH_KEY}" ]; then
  fail "SSH_KEY does not exist: ${SSH_KEY}"
fi

if [ -n "${SSH_PASSWORD}" ]; then
  need sshpass
fi

need ssh
need scp
need curl
need gzip
need tar
need openssl
if [ "${SKIP_DNS}" != true ]; then
  need python3
fi

ok "cloud-only remote build selected; local Docker is not required"
warn "1G compose and Caddyfile are validated on the remote Docker host during deploy"

if [ -n "${ENV_FILE}" ]; then
  if [ -n "${SSH_PASSWORD}" ] || [ -n "${CF_API_TOKEN:-}" ]; then
    if chmod_probe="$(stat -f %Lp "${ENV_FILE}" 2>/dev/null || stat -c %a "${ENV_FILE}" 2>/dev/null)"; then
      case "${chmod_probe}" in
        600|400) ok "env file permissions are restrictive: ${chmod_probe}" ;;
        *) warn "env file contains secrets; run chmod 600 ${ENV_FILE}" ;;
      esac
    fi
  fi
else
  warn "ENV_FILE is not set; use ENV_FILE=deploy/deploy-1g.env.local"
fi

if [ "${failures}" -ne 0 ]; then
  echo "1G deployment doctor failed: ${failures} failure(s), ${warnings} warning(s)" >&2
  exit 1
fi

echo "1G deployment doctor passed: ${warnings} warning(s)"
echo "Next: DEPLOY_MODE=preflight ENV_FILE=${ENV_FILE:-deploy/deploy-1g.env.local} deploy/deploy-1g.sh"
