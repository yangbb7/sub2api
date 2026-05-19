#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/deploy-1g.env.local}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "OK: $*"
}

reject_persisted_secret() {
  local name="$1"
  if awk -F= -v key="${name}" '
    $0 !~ /^[[:space:]]*#/ && $1 == key {
      sub(/^[^=]*=/, "")
      if (length($0) > 0) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "${ENV_FILE}"; then
    fail "${ENV_FILE} contains ${name}; export secrets in the shell instead"
  fi
}

has_shell_ssh_secret() {
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

if [ ! -f "${ENV_FILE}" ]; then
  fail "ENV_FILE does not exist: ${ENV_FILE}"
fi

mode="$(stat -f %Lp "${ENV_FILE}" 2>/dev/null || stat -c %a "${ENV_FILE}" 2>/dev/null || true)"
case "${mode}" in
  600|400) ok "env file permissions are restrictive: ${mode}" ;;
  *) fail "env file permissions are too open: ${mode:-unknown}; run chmod 600 ${ENV_FILE}" ;;
esac

reject_persisted_secret SSH_PASS
reject_persisted_secret SSH_PASSWORD
reject_persisted_secret JP_SSH_PASS
reject_persisted_secret JP_SSH_PASSWORD
reject_persisted_secret HK_SSH_PASS
reject_persisted_secret HK_SSH_PASSWORD
reject_persisted_secret SUDO_PASSWORD
reject_persisted_secret CF_API_TOKEN
ok "secrets are not persisted in ${ENV_FILE}"

if ! has_shell_ssh_secret; then
  fail "missing SSH auth env; export SSH_PASS or provide SSH_KEY in the shell"
fi
ok "SSH auth env is present"

if [ -z "${CF_API_TOKEN:-}" ]; then
  fail "missing CF_API_TOKEN env"
fi
ok "Cloudflare token env is present"

if ! ENV_FILE="${ENV_FILE}" "${DEPLOY_DIR}/doctor-1g.sh"; then
  fail "doctor check failed"
fi

ok "ready to start remote deploy"
