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
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_MEMORY_LIMIT=.*896m' \
  "deploy.sh must default green gateways to the 2C2G memory baseline"
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_GOMAXPROCS=.*:-2' \
  "deploy.sh must default green gateways to two Go scheduler threads"
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_GOMEMLIMIT=.*640MiB' \
  "deploy.sh must default green gateways to the Go memory limit baseline"
assert_not_contains "${DEPLOY_SCRIPT}" 'GATEWAY_OPENAI_FIRST_OUTPUT_TIMEOUT_SECONDS:-120' \
  "deploy.sh must not deploy the abandoned 120-second first-output default"
assert_not_contains "${DEPLOY_SCRIPT}" 'GATEWAY_OPENAI_HIGH_EFFORT_FIRST_OUTPUT_TIMEOUT_SECONDS:-600' \
  "deploy.sh must not deploy the abandoned 600-second high-effort timeout"
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_STREAM_KEEPALIVE_INTERVAL' \
  "deploy.sh must pass the reversible SSE keepalive switch to the green container"
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED' \
  "deploy.sh must pass the reversible stream-governance switch to the green container"
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS:-10' \
  "deploy.sh must default stream governance to a 10-second total budget"
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS:-6' \
  "deploy.sh must reserve a 6-second first-account budget"
assert_contains "${DEPLOY_SCRIPT}" 'set_env_override GATEWAY_STREAM_KEEPALIVE_INTERVAL' \
  "deploy.sh must apply SSE keepalive to the green container environment"
assert_contains "${DEPLOY_SCRIPT}" 'set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED' \
  "deploy.sh must apply stream governance to the green container environment"

runtime_env="$(mktemp)"
testable_deploy_script="$(mktemp)"
cleanup_runtime_env() {
  rm -f "${runtime_env}" "${testable_deploy_script}"
}
trap cleanup_runtime_env EXIT
sed '$d' "${DEPLOY_SCRIPT}" > "${testable_deploy_script}"
cat > "${runtime_env}" <<'EOF'
SSH_TARGET=deploy@example.net
GATEWAY_STREAM_KEEPALIVE_INTERVAL=5
GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=true
GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=10
GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS=10
GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS=6
EOF
runtime_values="$({
  ENV_FILE="${runtime_env}" bash -s "${testable_deploy_script}" <<'BASH'
unset GATEWAY_STREAM_KEEPALIVE_INTERVAL
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS
source "$1"
load_connection_defaults
validate_runtime_overrides
printf '%s %s %s %s %s\n' \
  "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}"
BASH
})"
[ "${runtime_values}" = "5 true 10 10 6" ] || {
  echo "deploy.sh did not load stream governance overrides from ENV_FILE: ${runtime_values}" >&2
  exit 1
}
runtime_values="$({
  GATEWAY_STREAM_KEEPALIVE_INTERVAL=10 \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=false \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=20 \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS=12 \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS=7 \
  ENV_FILE="${runtime_env}" bash -s "${testable_deploy_script}" <<'BASH'
source "$1"
load_connection_defaults
validate_runtime_overrides
printf '%s %s %s %s %s\n' \
  "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}"
BASH
})"
[ "${runtime_values}" = "10 false 20 12 7" ] || {
  echo "deploy.sh did not preserve shell stream governance overrides: ${runtime_values}" >&2
  exit 1
}
assert_contains "${DEPLOY_SCRIPT}" 'caddy reload' \
  "deploy.sh must hot-reload Caddy instead of recreating it"
assert_contains "${DEPLOY_SCRIPT}" 'https://\$\{DOMAIN\}/v1/responses' \
  "deploy.sh must verify /v1/responses is not a Cloudflare 521"
assert_contains "${DEPLOY_SCRIPT}" 'HEALTH_MIN_SUCCESS' \
  "deploy.sh must tolerate a small number of transient public health probe failures"
assert_contains "${DEPLOY_SCRIPT}" 'max_streak' \
  "deploy.sh must require a stable success streak before accepting a deploy"
assert_not_contains "${DEPLOY_SCRIPT}" '\[\s*"\$\{fail\}"\s*-ne\s*0\s*\]' \
  "deploy.sh must not roll back solely because one transient public probe failed"
assert_contains "${DEPLOY_SCRIPT}" 'cleanup_old_gateways' \
  "deploy.sh must prune old blue/green gateway containers after a verified deploy"
assert_contains "${DEPLOY_SCRIPT}" 'KEEP_ROLLBACKS' \
  "deploy.sh must keep a bounded number of rollback gateway containers"

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
