#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy.sh"
ROLLBACK_SCRIPT="${SCRIPT_DIR}/rollback.sh"
HUANA_SCRIPT="${SCRIPT_DIR}/huana-1g-deploy.sh"

require_file() {
  local path="$1"
  if [ ! -f "${path}" ]; then
    echo "Missing script: ${path}" >&2
    exit 1
  fi
}

assert_contains() {
  local path="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "${pattern}" "${path}"; then
    echo "${message}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eq "${pattern}" "${path}"; then
    echo "${message}" >&2
    exit 1
  fi
}

require_file "${DEPLOY_SCRIPT}"
require_file "${ROLLBACK_SCRIPT}"
require_file "${HUANA_SCRIPT}"

if [ -e "${SCRIPT_DIR}/Makefile" ]; then
  echo "deploy/Makefile is a dead misplaced backend Makefile; remove it" >&2
  exit 1
fi
if [ -e "${SCRIPT_DIR}/build_image.sh" ]; then
  echo "deploy/build_image.sh is an unreferenced duplicate docker build wrapper; remove it" >&2
  exit 1
fi

bash -n "${DEPLOY_SCRIPT}" "${ROLLBACK_SCRIPT}" "${HUANA_SCRIPT}"

assert_contains "${DEPLOY_SCRIPT}" 'DEPLOY_MODE=build' \
  "deploy.sh must only use the image build path from deploy-1g.sh"
assert_not_contains "${DEPLOY_SCRIPT}" 'DEPLOY_MODE=deploy' \
  "deploy.sh must not call the full compose deploy path"
assert_contains "${DEPLOY_SCRIPT}" 'docker inspect .*ACTIVE_GATEWAY.*Config\.Env' \
  "deploy.sh must copy runtime environment from the active healthy gateway"
assert_contains "${DEPLOY_SCRIPT}" 'docker run -d' \
  "deploy.sh must start a parallel gateway container"
assert_contains "${DEPLOY_SCRIPT}" 'caddy reload' \
  "deploy.sh must hot-reload Caddy instead of recreating it"
assert_contains "${DEPLOY_SCRIPT}" 'https://\$\{DOMAIN\}/v1/responses' \
  "deploy.sh must verify /v1/responses is not a Cloudflare 521"

assert_contains "${ROLLBACK_SCRIPT}" '^(usage|list_targets|select_previous_target|switch_caddy)' \
  "rollback.sh must expose list, previous selection, and Caddy switch helpers"
assert_contains "${ROLLBACK_SCRIPT}" 'previous' \
  "rollback.sh must support rolling back to the previous healthy container"
assert_contains "${ROLLBACK_SCRIPT}" 'to \[gateway-container\]' \
  "rollback.sh usage must document explicit target rollback"
assert_contains "${ROLLBACK_SCRIPT}" 'caddy reload' \
  "rollback.sh must hot-reload Caddy"
assert_contains "${ROLLBACK_SCRIPT}" 'gateway-\(green\|blue\|next\|rollback\)' \
  "rollback.sh must only consider app gateway containers, not gateway-caddy/postgres/redis"

for path in "${DEPLOY_SCRIPT}" "${ROLLBACK_SCRIPT}"; do
  assert_not_contains "${path}" 'docker compose .*up|docker compose .*down|docker compose .*force-recreate' \
    "${path} must not recreate compose services"
  assert_not_contains "${path}" 'POSTGRES_PASSWORD|JWT_SECRET|TOTP_ENCRYPTION_KEY' \
    "${path} must not read or write production secrets"
  assert_not_contains "${path}" 'mv .*\.env|cat > .*\.env|sed .*\.env' \
    "${path} must not rewrite production .env"
  assert_not_contains "${path}" 'cloudflare|CF_API_TOKEN' \
    "${path} must not touch DNS"
done

assert_contains "${HUANA_SCRIPT}" 'DEPRECATED|deprecated' \
  "huana-1g-deploy.sh must clearly mark itself deprecated"
assert_contains "${HUANA_SCRIPT}" 'deploy/deploy\.sh' \
  "huana-1g-deploy.sh must point users to deploy/deploy.sh"
assert_contains "${HUANA_SCRIPT}" 'deploy/rollback\.sh' \
  "huana-1g-deploy.sh must point users to deploy/rollback.sh"
assert_not_contains "${HUANA_SCRIPT}" 'DEPLOY_MODE=deploy|DEPLOY_MODE=preflight|verify-live-1g\.sh|ready-1g\.sh' \
  "huana-1g-deploy.sh must not call the old full deploy chain"

echo "simple production deploy/rollback script tests passed"
