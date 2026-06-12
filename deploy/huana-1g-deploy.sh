#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/deploy-1g.env.local}"
DOMAIN="${DOMAIN:-}"
DRY_RUN="${DRY_RUN:-false}"

case "${DRY_RUN}" in
  true|false) ;;
  *)
    echo "DRY_RUN must be true or false" >&2
    exit 1
    ;;
esac

ensure_env_file() {
  if [ -f "${ENV_FILE}" ]; then
    return
  fi
  if [ -z "${DOMAIN}" ]; then
    echo "ENV_FILE does not exist and DOMAIN is not set: ${ENV_FILE}" >&2
    echo "Use deploy/deploy.sh from an initialized checkout, or set DOMAIN once to create ${ENV_FILE}." >&2
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

cat >&2 <<EOF
DEPRECATED: deploy/huana-1g-deploy.sh is no longer the production deploy entry.
Use:
  deploy/deploy.sh
Rollback:
  deploy/rollback.sh
EOF

if [ "${DRY_RUN}" = true ]; then
  echo "Would run: deploy/deploy.sh"
  exit 0
fi

ENV_FILE="${ENV_FILE}" "${DEPLOY_DIR}/deploy.sh"
