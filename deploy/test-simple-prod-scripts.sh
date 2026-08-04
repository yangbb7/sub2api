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
  if ! grep -Eq -- "${pattern}" "${path}"; then
    echo "${message}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eq -- "${pattern}" "${path}"; then
    echo "${message}" >&2
    exit 1
  fi
}

assert_last_order() {
  local path="$1"
  local first_pattern="$2"
  local second_pattern="$3"
  local message="$4"
  local first_line
  local second_line
  first_line="$(grep -En -- "${first_pattern}" "${path}" | tail -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -En -- "${second_pattern}" "${path}" | tail -n 1 | cut -d: -f1 || true)"
  if [ -z "${first_line}" ] || [ -z "${second_line}" ] || [ "${first_line}" -ge "${second_line}" ]; then
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
assert_contains "${DEPLOY_SCRIPT}" 'GATEWAY_RESPONSES_MAX_BODY_SIZE' \
  "deploy.sh must expose the optional Responses request-body budget"

runtime_env="$(mktemp)"
testable_deploy_script="$(mktemp)"
serial_remote_script="$(mktemp)"
serial_preflight_script="$(mktemp)"
serial_preflight_log="$(mktemp)"
serial_preflight_dir="$(mktemp -d)"
missing_governance_env="$(mktemp)"
deploy_lock_dir="$(mktemp -d)"
cleanup_runtime_env() {
  rm -f "${runtime_env}" "${testable_deploy_script}" "${serial_remote_script}" "${serial_preflight_script}" "${serial_preflight_log}" "${missing_governance_env}"
  rm -rf "${serial_preflight_dir}"
  rmdir "${deploy_lock_dir}" 2>/dev/null || true
}
trap cleanup_runtime_env EXIT
rmdir "${deploy_lock_dir}"
sed '$d' "${DEPLOY_SCRIPT}" > "${testable_deploy_script}"
cat > "${runtime_env}" <<'EOF'
SSH_TARGET=deploy@example.net
GATEWAY_STREAM_KEEPALIVE_INTERVAL=5
GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=true
GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=10
GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS=10
GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS=6
GATEWAY_RESPONSES_MAX_BODY_SIZE=4194304
EOF
runtime_values="$({
  ENV_FILE="${runtime_env}" bash -s "${testable_deploy_script}" <<'BASH'
unset GATEWAY_STREAM_KEEPALIVE_INTERVAL
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS
unset GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS
unset GATEWAY_RESPONSES_MAX_BODY_SIZE
source "$1"
load_connection_defaults
validate_runtime_overrides
printf '%s %s %s %s %s %s\n' \
  "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}" \
  "${GATEWAY_RESPONSES_MAX_BODY_SIZE}"
BASH
})"
[ "${runtime_values}" = "5 true 10 10 6 4194304" ] || {
  echo "deploy.sh did not load stream governance overrides from ENV_FILE: ${runtime_values}" >&2
  exit 1
}
if ENV_FILE="${missing_governance_env}" bash -s "${testable_deploy_script}" 2>/dev/null <<'BASH'
source "$1"
load_connection_defaults
BASH
then
  echo "deploy.sh must reject omitted stream-governance enablement instead of defaulting it to false" >&2
  exit 1
fi
runtime_values="$({
  GATEWAY_STREAM_KEEPALIVE_INTERVAL=10 \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=false \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=20 \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS=12 \
  GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS=7 \
  GATEWAY_RESPONSES_MAX_BODY_SIZE=0 \
  ENV_FILE="${runtime_env}" bash -s "${testable_deploy_script}" <<'BASH'
source "$1"
load_connection_defaults
validate_runtime_overrides
printf '%s %s %s %s %s %s\n' \
  "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}" \
  "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}" \
  "${GATEWAY_RESPONSES_MAX_BODY_SIZE}"
BASH
})"
[ "${runtime_values}" = "10 false 20 12 7 0" ] || {
  echo "deploy.sh did not preserve shell stream governance overrides: ${runtime_values}" >&2
  exit 1
}
DEPLOY_LOCK_DIR="${deploy_lock_dir}" bash -s "${testable_deploy_script}" <<'BASH'
source "$1"
acquire_deploy_lock
if DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR}" bash -s "$1" 2>/dev/null <<'CHILD'
source "$1"
acquire_deploy_lock
CHILD
then
  echo "deploy.sh did not reject a concurrent local deploy" >&2
  exit 1
fi
[ -f "${DEPLOY_LOCK_DIR}/owner" ]
release_deploy_lock
[ ! -e "${DEPLOY_LOCK_DIR}" ]
BASH
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
assert_contains "${DEPLOY_SCRIPT}" 'DEPLOY_STRATEGY=.*auto' \
  "deploy.sh must automatically use serial deployment on memory-constrained hosts"
assert_contains "${DEPLOY_SCRIPT}" 'stop_inactive_gateways' \
  "deploy.sh serial mode must release inactive rollback containers before cutover"
assert_contains "${DEPLOY_SCRIPT}" 'acquire_deploy_lock' \
  "deploy.sh must reject concurrent local production deployments"
assert_contains "${DEPLOY_SCRIPT}" 'Caddy upstream changed while the image was building' \
  "deploy.sh must refuse a stale cutover when another deploy changed Caddy"
assert_contains "${DEPLOY_SCRIPT}" 'docker run --rm --network none --memory' \
  "deploy.sh serial mode must validate the image without a second gateway server"
assert_contains "${DEPLOY_SCRIPT}" 'SERIAL_MIN_AVAILABLE_KB' \
  "deploy.sh serial mode must reject an unsafe candidate overlap before traffic changes"
assert_contains "${DEPLOY_SCRIPT}" 'SERIAL_DRAIN_SECONDS' \
  "deploy.sh serial mode must drain established streams after Caddy switches"
assert_contains "${DEPLOY_SCRIPT}" 'apply_steady_state_resource_limits' \
  "deploy.sh must apply the 2C2G Caddy/Postgres/Redis memory baseline after cutover"
assert_contains "${DEPLOY_SCRIPT}" 'BindAddress=\$\{SSH_BIND_ADDRESS\}' \
  "deploy.sh must support binding operations to a healthy local SSH interface"

strategy_values="$({
  ENV_FILE="${runtime_env}" bash -s "${testable_deploy_script}" <<'BASH'
source "$1"
run_ssh() { printf '%s\n' "${TEST_MEMTOTAL_KB}"; }
DEPLOY_STRATEGY=auto
BLUE_GREEN_MIN_MEMORY_KB=3670016
TEST_MEMTOTAL_KB=2015232
printf '%s ' "$(select_deploy_strategy)"
TEST_MEMTOTAL_KB=4194304
printf '%s\n' "$(select_deploy_strategy)"
BASH
})"
[ "${strategy_values}" = "serial bluegreen" ] || {
  echo "deploy.sh did not select serial/bluegreen by remote memory: ${strategy_values}" >&2
  exit 1
}

REMOTE_SCRIPT_OUTPUT="${serial_preflight_script}" \
REMOTE_DIR="${serial_preflight_dir}" \
SERIAL_CANARY_MEMORY_LIMIT=256m \
bash -s "${testable_deploy_script}" <<'BASH'
source "$1"
run_remote_root_script() { cp "$1" "$REMOTE_SCRIPT_OUTPUT"; }
start_serial_candidate gateway-green-old abcdef123456
BASH
bash -n "${serial_preflight_script}"
assert_contains "${serial_preflight_script}" 'serial_supporting_limit_before' \
  "serial image preflight must audit legacy supporting-service cgroup limits"
assert_contains "${serial_preflight_script}" 'docker update --memory "\$\{memory_limit\}" --memory-swap "\$\{memory_limit\}" "\$\{service\}"' \
  "serial image preflight must set finite Caddy, Postgres, and Redis memory/swap limits"
assert_contains "${serial_preflight_script}" 'serial_host_budget_bytes' \
  "serial image preflight must calculate a bounded 2GiB host budget"
assert_last_order "${serial_preflight_script}" 'preflight_serial_supporting_limits' 'docker run --rm' \
  "serial image preflight must limit legacy services before any candidate container starts"

mkdir -p "${serial_preflight_dir}/bin"
cat > "${serial_preflight_dir}/bin/docker" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG}"
case "$1" in
  inspect)
    case "$*" in
      *gateway:cloud*) printf '%s\n' abcdef123456 ;;
      *gateway-green-old*State.Health*) printf '%s\n' healthy ;;
      *gateway-green-old*) printf '%s\n' 1610612736 ;;
      *) printf '%s\n' 1 ;;
    esac
    ;;
  update) ;;
  run)
    echo "candidate docker run must be unreachable after an over-budget preflight" >&2
    exit 99
    ;;
  *)
    echo "unexpected docker command: $*" >&2
    exit 98
    ;;
esac
BASH
chmod +x "${serial_preflight_dir}/bin/docker"
set +e
PATH="${serial_preflight_dir}/bin:${PATH}" DOCKER_LOG="${serial_preflight_log}" bash "${serial_preflight_script}" >/dev/null 2>&1
serial_preflight_status=$?
set -e
[ "${serial_preflight_status}" -ne 0 ] || {
  echo "serial image preflight accepted an over-budget legacy stack" >&2
  exit 1
}
grep -Fq 'update --memory 96m --memory-swap 96m gateway-caddy' "${serial_preflight_log}" || {
  echo "serial image preflight did not limit Caddy before rejecting an over-budget stack" >&2
  exit 1
}
if grep -Fq 'run ' "${serial_preflight_log}"; then
  echo "serial image preflight started a candidate after rejecting an over-budget legacy stack" >&2
  exit 1
fi

REMOTE_SCRIPT_OUTPUT="${serial_remote_script}" \
REMOTE_DIR=/opt/gateway \
GATEWAY_MEMORY_LIMIT=896m \
GATEWAY_GOMAXPROCS=2 \
GATEWAY_GOMEMLIMIT=640MiB \
GATEWAY_STREAM_KEEPALIVE_INTERVAL=5 \
GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=true \
GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=10 \
GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS=10 \
GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS=6 \
SERIAL_CANARY_MEMORY_LIMIT=256m \
SERIAL_DRAIN_SECONDS=15 \
SERIAL_MIN_AVAILABLE_KB=524288 \
bash -s "${testable_deploy_script}" <<'BASH'
source "$1"
run_remote_root_script() { cp "$1" "$REMOTE_SCRIPT_OUTPUT"; }
promote_serial_candidate gateway-green-old abcdef123456 gateway-green-abcdef123456-rollout
BASH
bash -n "${serial_remote_script}"
assert_contains "${serial_remote_script}" "NEXT_GATEWAY='gateway-green-abcdef123456-rollout'" \
  "serial cutover must accept a unique rollout container name"
assert_contains "${serial_remote_script}" 'docker run -d' \
  "serial remote cutover must start a live replacement gateway"
assert_contains "${serial_remote_script}" 'MemAvailable' \
  "serial remote cutover must check available host memory before overlap"
assert_contains "${serial_remote_script}" "GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED='true'" \
  "serial cutover must preserve the enabled governance canary from ENV_FILE"
assert_contains "${serial_remote_script}" 'set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED "\$\{GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED\}"' \
  "serial cutover must write the enabled governance canary into the next container environment"
assert_contains "${serial_remote_script}" '--memory-swap "\$\{CANARY_MEMORY_LIMIT\}"' \
  "serial candidate must use a finite swap limit while the old gateway remains live"
assert_contains "${serial_remote_script}" 'http://\$\{NEXT_GATEWAY\}:18080/health' \
  "serial remote cutover must prove Caddy can reach the candidate before switching"
assert_contains "${serial_remote_script}" 'docker update --memory "\$\{GATEWAY_MEMORY_LIMIT\}".*"\$\{NEXT_GATEWAY\}"' \
  "serial remote cutover must restore the candidate's steady-state memory after draining"
assert_not_contains "${serial_remote_script}" 'ACTIVE_MEMORY_SWAP|--memory-swap -1' \
  "serial remote cutover must not restore an unbounded swap limit"
assert_contains "${serial_remote_script}" '--memory-swap' \
  "serial remote cutover must update memory and swap together"
assert_last_order "${serial_remote_script}" 'docker run -d' 'docker stop "\$\{ACTIVE_GATEWAY\}"' \
  "serial remote cutover must start the candidate before stopping the active gateway"
assert_last_order "${serial_remote_script}" 'caddy reload --config /tmp/Caddyfile.next' 'docker stop "\$\{ACTIVE_GATEWAY\}"' \
  "serial remote cutover must switch Caddy before stopping the active gateway"
assert_contains "${serial_remote_script}" 'restore_active' \
  "serial remote cutover must restore the active gateway if the replacement fails"

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
assert_contains "${ROLLBACK_SCRIPT}" 'docker ps -a' \
  "rollback.sh must show and select stopped serial rollback containers"
assert_contains "${ROLLBACK_SCRIPT}" 'docker stop.*current' \
  "rollback.sh must avoid overlapping full gateways when restoring a stopped target"
assert_contains "${ROLLBACK_SCRIPT}" 'BindAddress=\$\{SSH_BIND_ADDRESS\}' \
  "rollback.sh must use the configured healthy local SSH interface"

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
