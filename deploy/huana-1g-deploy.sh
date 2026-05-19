#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/deploy-1g.env.local}"
DOMAIN="${DOMAIN:-}"
DRY_RUN="${DRY_RUN:-false}"
RUN_PREFLIGHT="${RUN_PREFLIGHT:-true}"
RUN_CHECK="${RUN_CHECK:-true}"

case "${DRY_RUN}" in
  true|false) ;;
  *)
    echo "DRY_RUN must be true or false" >&2
    exit 1
    ;;
esac

case "${RUN_PREFLIGHT}" in
  true|false) ;;
  *)
    echo "RUN_PREFLIGHT must be true or false" >&2
    exit 1
    ;;
esac

case "${RUN_CHECK}" in
  true|false) ;;
  *)
    echo "RUN_CHECK must be true or false" >&2
    exit 1
    ;;
esac

has_ssh_secret() {
  [ -n "${SSH_PASS:-}" ] ||
    [ -n "${SSH_PASSWORD:-}" ] ||
    [ -n "${JP_SSH_PASS:-}" ] ||
    [ -n "${JP_SSH_PASSWORD:-}" ] ||
    [ -n "${HK_SSH_PASS:-}" ] ||
    [ -n "${HK_SSH_PASSWORD:-}" ] ||
    [ -n "${SSH_KEY:-}" ] ||
    [ -n "${JP_SSH_KEY:-}" ] ||
    [ -n "${HK_SSH_KEY:-}" ]
}

ensure_env_file() {
  if [ -f "${ENV_FILE}" ]; then
    return
  fi
  if [ -z "${DOMAIN}" ]; then
    echo "ENV_FILE does not exist and DOMAIN is not set: ${ENV_FILE}" >&2
    echo "Run DOMAIN=api.example.com deploy/huana-1g-deploy.sh" >&2
    exit 1
  fi
  ENV_FILE="${ENV_FILE}" DOMAIN="${DOMAIN}" "${DEPLOY_DIR}/init-huana-1g-env.sh"
}

reject_persisted_secret() {
  local name="$1"
  if grep -Eq "^${name}=.+" "${ENV_FILE}"; then
    echo "${ENV_FILE} contains ${name}; keep secrets in shell env, not in this file" >&2
    exit 1
  fi
}

print_step() {
  printf '%s\n' "$1"
}

run_doctor() {
  if [ "${DRY_RUN}" = true ]; then
    print_step "Would run: ENV_FILE=${ENV_FILE} deploy/ready-1g.sh"
    return
  fi
  ENV_FILE="${ENV_FILE}" "${DEPLOY_DIR}/ready-1g.sh"
}

run_preflight() {
  if [ "${DRY_RUN}" = true ]; then
    print_step "Would run: DEPLOY_MODE=preflight ENV_FILE=${ENV_FILE} deploy/deploy-1g.sh"
    return
  fi
  DEPLOY_MODE=preflight ENV_FILE="${ENV_FILE}" "${DEPLOY_DIR}/deploy-1g.sh"
}

run_deploy() {
  if [ "${DRY_RUN}" = true ]; then
    print_step "Would run: DEPLOY_MODE=deploy ENV_FILE=${ENV_FILE} deploy/deploy-1g.sh"
    return
  fi
  DEPLOY_MODE=deploy ENV_FILE="${ENV_FILE}" "${DEPLOY_DIR}/deploy-1g.sh"
}

run_check() {
  if [ "${DRY_RUN}" = true ]; then
    print_step "Would run: ENV_FILE=${ENV_FILE} deploy/verify-live-1g.sh"
    return
  fi
  ENV_FILE="${ENV_FILE}" "${DEPLOY_DIR}/verify-live-1g.sh"
}

ensure_env_file
chmod 600 "${ENV_FILE}"

reject_persisted_secret SSH_PASS
reject_persisted_secret SSH_PASSWORD
reject_persisted_secret JP_SSH_PASS
reject_persisted_secret JP_SSH_PASSWORD
reject_persisted_secret HK_SSH_PASS
reject_persisted_secret HK_SSH_PASSWORD
reject_persisted_secret SUDO_PASSWORD
reject_persisted_secret CF_API_TOKEN

if ! has_ssh_secret; then
  echo "Missing SSH auth env. Export SSH_PASS, a region-specific SSH password, or SSH_KEY." >&2
  exit 1
fi

if [ -z "${CF_API_TOKEN:-}" ]; then
  echo "Missing CF_API_TOKEN env. Cloudflare DNS update is part of this deployment." >&2
  exit 1
fi

run_doctor
if [ "${RUN_PREFLIGHT}" = true ]; then
  run_preflight
fi
run_deploy
if [ "${RUN_CHECK}" = true ]; then
  run_check
fi
