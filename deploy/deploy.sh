#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy-1g.env.local}"
DOMAIN="${DOMAIN:-api.braintech.icu}"
REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
TARGET_REGION="${TARGET_REGION:-jp}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
SSH_BIND_ADDRESS="${SSH_BIND_ADDRESS:-}"
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-60}"
HEALTH_SLEEP="${HEALTH_SLEEP:-0.2}"
HEALTH_MIN_SUCCESS="${HEALTH_MIN_SUCCESS:-10}"
HEALTH_REQUIRED_STREAK="${HEALTH_REQUIRED_STREAK:-5}"
# local is the normal path: it proves the deploy operator can reach the
# public edge. remote is an explicit break-glass path for a workstation whose
# network stack is unhealthy; the protected source host still goes through
# Cloudflare and Caddy, so it does not bypass public-route verification.
PUBLIC_VERIFICATION_SOURCE="${PUBLIC_VERIFICATION_SOURCE:-local}"
KEEP_ROLLBACKS="${KEEP_ROLLBACKS:-1}"
DEPLOY_STRATEGY="${DEPLOY_STRATEGY:-auto}"
# A 2GiB host cannot retain two full 896MiB gateways during a blue-green
# cutover. The serial strategy briefly overlaps the active gateway with a
# capped, live candidate, switches Caddy only after it is healthy, then stops
# the old gateway and restores the candidate to its steady-state limit.
SERIAL_CANARY_MEMORY_LIMIT="${SERIAL_CANARY_MEMORY_LIMIT:-}"
SERIAL_DRAIN_SECONDS="${SERIAL_DRAIN_SECONDS:-}"
SERIAL_MIN_AVAILABLE_KB="${SERIAL_MIN_AVAILABLE_KB:-}"
BLUE_GREEN_MIN_MEMORY_KB="${BLUE_GREEN_MIN_MEMORY_KB:-3670016}"
GATEWAY_MEMORY_LIMIT="${GATEWAY_MEMORY_LIMIT:-}"
GATEWAY_GOMAXPROCS="${GATEWAY_GOMAXPROCS:-}"
GATEWAY_GOMEMLIMIT="${GATEWAY_GOMEMLIMIT:-}"
GATEWAY_STREAM_KEEPALIVE_INTERVAL="${GATEWAY_STREAM_KEEPALIVE_INTERVAL:-}"
GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED="${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED:-}"
GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT="${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT:-}"
GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS="${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS:-}"
GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS="${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS:-}"
GATEWAY_RESPONSES_MAX_BODY_SIZE="${GATEWAY_RESPONSES_MAX_BODY_SIZE:-}"
DEPLOY_LOCK_DIR="${DEPLOY_LOCK_DIR:-${TMPDIR:-/tmp}/sub2api-deploy.lock}"

usage() {
  cat <<'EOF'
Usage:
  deploy/deploy.sh

What it does:
  1. Requires local HEAD to match origin/main unless ALLOW_UNPUSHED=1.
  2. Builds the embedded frontend and linux gateway binary locally.
  3. Builds gateway:cloud on the production server.
  4. Chooses blue-green when memory permits, otherwise a 2GiB-safe serial cutover.
  5. Hot-reloads Caddy to the verified new container after health checks pass.

Required:
  SSH access to the production host configured in deploy/deploy-1g.env.local,
  or SSH_TARGET/SSH_KEY/SSH_PASS exported in your shell.

Emergency rollback:
  deploy/rollback.sh
EOF
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

# A full production build can take several minutes. Do not allow a second
# invocation from the same workstation to retain a stale Caddy upstream and
# later stop the container selected by the first invocation.
release_deploy_lock() {
	rm -f "${DEPLOY_LOCK_DIR}/owner" 2>/dev/null || true
	rmdir "${DEPLOY_LOCK_DIR}" 2>/dev/null || true
}

acquire_deploy_lock() {
	if ! mkdir "${DEPLOY_LOCK_DIR}" 2>/dev/null; then
		die "Another deploy/deploy.sh invocation is active (lock: ${DEPLOY_LOCK_DIR}). Wait for it to finish before retrying."
	fi
	printf 'pid=%s started_at=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${DEPLOY_LOCK_DIR}/owner"
	trap release_deploy_lock EXIT
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

single_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

env_file_value() {
  local key="$1"
  [ -f "${ENV_FILE}" ] || return 0
  awk -v key="${key}" '
    BEGIN { FS = "=" }
    $1 == key {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "${ENV_FILE}"
}

default_from_env_file() {
  local name="$1"
  local value
  if [ -z "${!name:-}" ]; then
    value="$(env_file_value "${name}")"
    if [ -n "${value}" ]; then
      printf -v "${name}" '%s' "${value}"
    fi
  fi
}

load_connection_defaults() {
  local name
  for name in \
    TARGET_REGION DOMAIN REMOTE_DIR SSH_TARGET SSH_PORT SSH_KEY SSH_PASSWORD SSH_PASS SUDO_PASSWORD SSH_BIND_ADDRESS PUBLIC_VERIFICATION_SOURCE \
    DEPLOY_STRATEGY SERIAL_CANARY_MEMORY_LIMIT SERIAL_DRAIN_SECONDS SERIAL_MIN_AVAILABLE_KB BLUE_GREEN_MIN_MEMORY_KB \
    GATEWAY_MEMORY_LIMIT GATEWAY_GOMAXPROCS GATEWAY_GOMEMLIMIT \
    GATEWAY_STREAM_KEEPALIVE_INTERVAL GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED \
    GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS \
    GATEWAY_RESPONSES_MAX_BODY_SIZE \
    JP_SSH_TARGET JP_SSH_PORT JP_SSH_KEY JP_SSH_PASSWORD JP_SSH_PASS \
    HK_SSH_TARGET HK_SSH_PORT HK_SSH_KEY HK_SSH_PASSWORD HK_SSH_PASS
  do
    default_from_env_file "${name}"
  done

  # These rollout controls are approved per deployment in ENV_FILE or the
  # caller's environment. Never silently replace an approved canary with a
  # disabled global fallback.
  GATEWAY_STREAM_KEEPALIVE_INTERVAL="${GATEWAY_STREAM_KEEPALIVE_INTERVAL:-0}"
  [ -n "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}" ] || die "GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED must be explicitly set in ENV_FILE or the environment."
  GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT="${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT:-10}"
  GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS="${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS:-10}"
  GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS="${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS:-6}"
  SERIAL_CANARY_MEMORY_LIMIT="${SERIAL_CANARY_MEMORY_LIMIT:-256m}"
  SERIAL_DRAIN_SECONDS="${SERIAL_DRAIN_SECONDS:-15}"
  SERIAL_MIN_AVAILABLE_KB="${SERIAL_MIN_AVAILABLE_KB:-524288}"
  PUBLIC_VERIFICATION_SOURCE="${PUBLIC_VERIFICATION_SOURCE:-local}"

  SSH_PASSWORD="${SSH_PASSWORD:-${SSH_PASS:-}}"
  case "${TARGET_REGION}" in
    jp|japan)
      SSH_TARGET="${SSH_TARGET:-${JP_SSH_TARGET:-}}"
      SSH_PORT="${SSH_PORT:-${JP_SSH_PORT:-}}"
      SSH_KEY="${SSH_KEY:-${JP_SSH_KEY:-}}"
      SSH_PASSWORD="${SSH_PASSWORD:-${JP_SSH_PASSWORD:-${JP_SSH_PASS:-}}}"
      ;;
    hk|hongkong)
      SSH_TARGET="${SSH_TARGET:-${HK_SSH_TARGET:-}}"
      SSH_PORT="${SSH_PORT:-${HK_SSH_PORT:-}}"
      SSH_KEY="${SSH_KEY:-${HK_SSH_KEY:-}}"
      SSH_PASSWORD="${SSH_PASSWORD:-${HK_SSH_PASSWORD:-${HK_SSH_PASS:-}}}"
      ;;
    auto|"") ;;
    *) die "TARGET_REGION must be jp, hk, auto, or empty" ;;
  esac

  [ -n "${SSH_TARGET:-}" ] || die "SSH_TARGET is empty. Set TARGET_REGION=jp with JP_SSH_TARGET, or export SSH_TARGET."
  if [ -n "${SSH_KEY:-}" ] && [ -n "${SSH_PASSWORD:-}" ]; then
    die "Use SSH_KEY or SSH_PASS/SSH_PASSWORD, not both."
  fi
  if [ -n "${SSH_BIND_ADDRESS:-}" ]; then
    case "${SSH_BIND_ADDRESS}" in
      *[!0-9.]*|.*|*..*|*.) die "SSH_BIND_ADDRESS must be an IPv4 address." ;;
    esac
  fi
}

validate_simple_token() {
  local name="$1"
  local value="$2"
  [ -z "${value}" ] && return 0
  case "${value}" in
    *[!A-Za-z0-9_.:-]*)
      die "${name} contains unsupported characters."
      ;;
  esac
}

validate_runtime_overrides() {
  # This is the steady-state 2C2G streaming baseline. Blue-green overlap
  # needs a separate host-capacity preflight; do not silently fall back to
  # the old 1C1G process settings.
  GATEWAY_MEMORY_LIMIT="${GATEWAY_MEMORY_LIMIT:-896m}"
  GATEWAY_GOMAXPROCS="${GATEWAY_GOMAXPROCS:-2}"
  GATEWAY_GOMEMLIMIT="${GATEWAY_GOMEMLIMIT:-640MiB}"
  validate_simple_token GATEWAY_MEMORY_LIMIT "${GATEWAY_MEMORY_LIMIT}"
  validate_simple_token SERIAL_CANARY_MEMORY_LIMIT "${SERIAL_CANARY_MEMORY_LIMIT}"
  validate_simple_token SERIAL_DRAIN_SECONDS "${SERIAL_DRAIN_SECONDS}"
  validate_simple_token SERIAL_MIN_AVAILABLE_KB "${SERIAL_MIN_AVAILABLE_KB}"
  validate_simple_token BLUE_GREEN_MIN_MEMORY_KB "${BLUE_GREEN_MIN_MEMORY_KB}"
  validate_simple_token GATEWAY_GOMAXPROCS "${GATEWAY_GOMAXPROCS:-}"
  validate_simple_token GATEWAY_GOMEMLIMIT "${GATEWAY_GOMEMLIMIT:-}"
  validate_simple_token GATEWAY_STREAM_KEEPALIVE_INTERVAL "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}"
  validate_simple_token GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}"
  validate_simple_token GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}"
  validate_simple_token GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}"
  validate_simple_token GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}"

  if [ -n "${GATEWAY_RESPONSES_MAX_BODY_SIZE}" ]; then
    case "${GATEWAY_RESPONSES_MAX_BODY_SIZE}" in
      *[!0-9]*) die "GATEWAY_RESPONSES_MAX_BODY_SIZE must be a non-negative integer." ;;
    esac
  fi
  if [ -n "${GATEWAY_GOMAXPROCS:-}" ]; then
    case "${GATEWAY_GOMAXPROCS}" in
      ''|*[!0-9]*) die "GATEWAY_GOMAXPROCS must be a positive integer." ;;
      0) die "GATEWAY_GOMAXPROCS must be a positive integer." ;;
    esac
  fi
  case "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}" in
    0|[5-9]|[12][0-9]|30) ;;
    *) die "GATEWAY_STREAM_KEEPALIVE_INTERVAL must be 0 or 5-30 seconds." ;;
  esac
  case "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}" in
    true|false) ;;
    *) die "GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED must be true or false." ;;
  esac
  case "${DEPLOY_STRATEGY}" in
    auto|bluegreen|serial) ;;
    *) die "DEPLOY_STRATEGY must be auto, bluegreen, or serial." ;;
  esac
  case "${PUBLIC_VERIFICATION_SOURCE}" in
    local|remote) ;;
    *) die "PUBLIC_VERIFICATION_SOURCE must be local or remote." ;;
  esac
  case "${BLUE_GREEN_MIN_MEMORY_KB}" in
    ''|*[!0-9]*) die "BLUE_GREEN_MIN_MEMORY_KB must be a positive integer." ;;
  esac
  [ "${BLUE_GREEN_MIN_MEMORY_KB}" -gt 0 ] || die "BLUE_GREEN_MIN_MEMORY_KB must be a positive integer."
  for value_name in SERIAL_DRAIN_SECONDS SERIAL_MIN_AVAILABLE_KB; do
    case "${!value_name}" in
      ''|*[!0-9]*) die "${value_name} must be a non-negative integer." ;;
    esac
  done
  [ "${SERIAL_MIN_AVAILABLE_KB}" -gt 0 ] || die "SERIAL_MIN_AVAILABLE_KB must be a positive integer."
  for value_name in GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS; do
    case "${!value_name}" in
      ''|*[!0-9]*) die "${value_name} must be an integer." ;;
    esac
  done
  if [ "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}" -gt 100 ] ||
    [ "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}" -lt 1 ] ||
    [ "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}" -gt 30 ] ||
    [ "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}" -lt 1 ] ||
    [ "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}" -ge "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}" ]; then
    die "OpenAI stream governance requires rollout 0-100 and a first-attempt budget below the 1-30s total budget."
  fi
}

ssh_args() {
  local args=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT}"
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
  )
  [ -n "${SSH_PORT:-}" ] && args+=(-p "${SSH_PORT}")
  [ -n "${SSH_KEY:-}" ] && args+=(-i "${SSH_KEY}")
  [ -n "${SSH_BIND_ADDRESS:-}" ] && args+=(-o "BindAddress=${SSH_BIND_ADDRESS}")
  printf '%s\0' "${args[@]}"
}

run_ssh() {
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("${arg}")
  done < <(ssh_args)
  if [ -n "${SSH_PASSWORD:-}" ]; then
    need sshpass
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${args[@]}" "${SSH_TARGET}" "$@"
  else
    ssh "${args[@]}" "${SSH_TARGET}" "$@"
  fi
}

run_scp() {
  local args=()
  while IFS= read -r -d '' arg; do
    case "${arg}" in
      -p) args+=(-P) ;;
      *) args+=("${arg}") ;;
    esac
  done < <(ssh_args)
  if [ -n "${SSH_PASSWORD:-}" ]; then
    need sshpass
    SSHPASS="${SSH_PASSWORD}" sshpass -e scp "${args[@]}" "$@"
  else
    scp "${args[@]}" "$@"
  fi
}

run_remote_root_script() {
  local local_script="$1"
  local remote_script="/tmp/sub2api-deploy-$(date -u +%Y%m%dT%H%M%SZ)-$$.sh"
  local uid
  run_scp "${local_script}" "${SSH_TARGET}:${remote_script}" >/dev/null
  run_ssh "chmod 700 $(single_quote "${remote_script}")"
  uid="$(run_ssh "id -u")"
  if [ "${uid}" = 0 ]; then
    run_ssh "bash $(single_quote "${remote_script}"); status=\$?; rm -f $(single_quote "${remote_script}"); exit \$status"
  elif [ -n "${SUDO_PASSWORD:-}" ]; then
    run_ssh "printf '%s\n' $(single_quote "${SUDO_PASSWORD}") | sudo -S bash $(single_quote "${remote_script}"); status=\$?; rm -f $(single_quote "${remote_script}"); exit \$status"
  else
    run_ssh "sudo -n bash $(single_quote "${remote_script}"); status=\$?; rm -f $(single_quote "${remote_script}"); exit \$status"
  fi
}

require_clean_head() {
  git -C "${ROOT_DIR}" fetch origin
  local head origin status_output
  head="$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD)"
  origin="$(git -C "${ROOT_DIR}" rev-parse --short=12 origin/main)"
  status_output="$(git -C "${ROOT_DIR}" status --porcelain)"
  [ -z "${status_output}" ] || die "Worktree is dirty. Commit or stash before deploying."
  if [ "${ALLOW_UNPUSHED:-0}" != 1 ] && [ "${head}" != "${origin}" ]; then
    die "HEAD (${head}) does not match origin/main (${origin}). Push first, or set ALLOW_UNPUSHED=1 deliberately."
  fi
}

select_deploy_strategy() {
  local memory_kb
  case "${DEPLOY_STRATEGY}" in
    bluegreen|serial)
      printf '%s\n' "${DEPLOY_STRATEGY}"
      return 0
      ;;
  esac

  memory_kb="$(run_ssh "awk '/^MemTotal:/ {print \$2; exit}' /proc/meminfo")"
  case "${memory_kb}" in
    ''|*[!0-9]*) die "Could not determine remote MemTotal for DEPLOY_STRATEGY=auto." ;;
  esac
  if [ "${memory_kb}" -lt "${BLUE_GREEN_MIN_MEMORY_KB}" ]; then
    printf '%s\n' serial
  else
    printf '%s\n' bluegreen
  fi
}

stop_inactive_gateways() {
  local active_gateway="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
ACTIVE_GATEWAY=$(single_quote "${active_gateway}")
docker ps --format '{{.Names}}' | grep -E '^(gateway$|gateway-(green|blue|next|rollback))' | while read -r name; do
  [ "\${name}" = "\${ACTIVE_GATEWAY}" ] && continue
  echo "stop inactive gateway before serial cutover: \${name}"
  docker stop "\${name}" >/dev/null
done
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

start_serial_candidate() {
  local active_gateway="$1"
  local commit="$2"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
ACTIVE_GATEWAY=$(single_quote "${active_gateway}")
EXPECTED_REVISION=$(single_quote "${commit}")
CANARY_MEMORY_LIMIT=$(single_quote "${SERIAL_CANARY_MEMORY_LIMIT}")

test "\$(docker inspect "\${ACTIVE_GATEWAY}" --format '{{.State.Health.Status}}')" = healthy
test "\$(docker inspect gateway:cloud --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "\${EXPECTED_REVISION}"
ACTIVE_MEMORY="\$(docker inspect "\${ACTIVE_GATEWAY}" --format '{{.HostConfig.Memory}}')"
case "\${ACTIVE_MEMORY}" in
  ''|*[!0-9]*|0)
    echo "Refusing serial candidate launch: active gateway has no finite memory cgroup limit." >&2
    exit 1
    ;;
esac
serial_canary_bytes() {
  case "\${CANARY_MEMORY_LIMIT}" in
    *[mM]) printf '%s\n' "\$(( \${CANARY_MEMORY_LIMIT%[mM]} * 1024 * 1024 ))" ;;
    *[gG]) printf '%s\n' "\$(( \${CANARY_MEMORY_LIMIT%[gG]} * 1024 * 1024 * 1024 ))" ;;
    *)
      echo "Refusing serial candidate launch: SERIAL_CANARY_MEMORY_LIMIT must use an m or g suffix for a bounded host-budget preflight." >&2
      exit 1
      ;;
  esac
}
preflight_serial_supporting_limits() {
  local service memory_limit memory swap
  for service in gateway-caddy gateway-postgres gateway-redis; do
    case "\${service}" in
      gateway-caddy) memory_limit=96m ;;
      gateway-postgres) memory_limit=320m ;;
      gateway-redis) memory_limit=128m ;;
    esac
    echo "serial_supporting_limit_before service=\${service} memory=\$(docker inspect "\${service}" --format '{{.HostConfig.Memory}}') swap=\$(docker inspect "\${service}" --format '{{.HostConfig.MemorySwap}}')"
    docker update --memory "\${memory_limit}" --memory-swap "\${memory_limit}" "\${service}" >/dev/null
    memory="\$(docker inspect "\${service}" --format '{{.HostConfig.Memory}}')"
    swap="\$(docker inspect "\${service}" --format '{{.HostConfig.MemorySwap}}')"
    case "\${memory}:\${swap}" in
      *[!0-9:]*|0:*|*:0)
        echo "Refusing serial candidate launch: \${service} does not have finite memory and swap cgroup limits." >&2
        exit 1
        ;;
    esac
    [ "\${memory}" = "\${swap}" ] || {
      echo "Refusing serial candidate launch: \${service} swap limit differs from its memory limit." >&2
      exit 1
    }
    echo "serial_supporting_limit_after service=\${service} memory=\${memory} swap=\${swap}"
  done
}
preflight_serial_supporting_limits
support_memory_bytes="\$(( 96 * 1024 * 1024 + 320 * 1024 * 1024 + 128 * 1024 * 1024 ))"
canary_memory_bytes="\$(serial_canary_bytes)"
serial_total_memory_bytes="\$(( ACTIVE_MEMORY + support_memory_bytes + canary_memory_bytes ))"
if [ "\${serial_total_memory_bytes}" -gt 2147483648 ]; then
  echo "Refusing serial candidate launch: active gateway plus bounded supporting services and candidate require \${serial_total_memory_bytes} bytes, above the 2GiB host budget." >&2
  exit 1
fi
echo "serial_host_budget_bytes=\${serial_total_memory_bytes}"
# This isolated check proves that the built image can execute before launching
# the bounded live candidate used for the no-gap serial cutover below.
docker run --rm --network none --memory "\${CANARY_MEMORY_LIMIT}" gateway:cloud --version >/dev/null
echo "serial_image_preflight_memory_limit=\${CANARY_MEMORY_LIMIT}"
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

promote_serial_candidate() {
  local active_gateway="$1"
  local commit="$2"
  local next_gateway="$3"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
ACTIVE_GATEWAY=$(single_quote "${active_gateway}")
NEXT_GATEWAY=$(single_quote "${next_gateway}")
GATEWAY_MEMORY_LIMIT=$(single_quote "${GATEWAY_MEMORY_LIMIT}")
GATEWAY_GOMAXPROCS=$(single_quote "${GATEWAY_GOMAXPROCS:-}")
GATEWAY_GOMEMLIMIT=$(single_quote "${GATEWAY_GOMEMLIMIT:-}")
CANARY_MEMORY_LIMIT=$(single_quote "${SERIAL_CANARY_MEMORY_LIMIT}")
SERIAL_DRAIN_SECONDS=$(single_quote "${SERIAL_DRAIN_SECONDS}")
SERIAL_MIN_AVAILABLE_KB=$(single_quote "${SERIAL_MIN_AVAILABLE_KB}")
GATEWAY_STREAM_KEEPALIVE_INTERVAL=$(single_quote "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}")
GATEWAY_RESPONSES_MAX_BODY_SIZE=$(single_quote "${GATEWAY_RESPONSES_MAX_BODY_SIZE}")

test "\$(docker inspect "\${ACTIVE_GATEWAY}" --format '{{.State.Health.Status}}')" = healthy
available_kb="\$(awk '/^MemAvailable:/ {print \$2; exit}' /proc/meminfo)"
case "\${available_kb}" in
  ''|*[!0-9]*)
    echo "Could not determine MemAvailable before serial candidate launch." >&2
    exit 1
    ;;
esac
if [ "\${available_kb}" -lt "\${SERIAL_MIN_AVAILABLE_KB}" ]; then
  echo "Refusing no-gap serial cutover: MemAvailable=\${available_kb}KiB is below required \${SERIAL_MIN_AVAILABLE_KB}KiB." >&2
  exit 1
fi
backup="Caddyfile.1g.before-\${NEXT_GATEWAY}-\$(date -u +%Y%m%dT%H%M%SZ).bak"
cp Caddyfile.1g "\${backup}"
sed "s/reverse_proxy \${ACTIVE_GATEWAY}:18080/reverse_proxy \${NEXT_GATEWAY}:18080/" "\${backup}" > Caddyfile.1g.next
if ! docker exec -i gateway-caddy sh -c 'cat > /tmp/Caddyfile.next && caddy validate --config /tmp/Caddyfile.next --adapter caddyfile' < Caddyfile.1g.next; then
  rm -f Caddyfile.1g.next
  exit 1
fi
env_file="\$(mktemp /tmp/gateway-serial-env.XXXXXX)"
restore_active() {
  rm -f "\${env_file}" Caddyfile.1g.next
  active_ready=false
  active_state="\$(docker inspect "\${ACTIVE_GATEWAY}" --format '{{.State.Status}}' 2>/dev/null || true)"
  if [ "\${active_state}" != running ]; then
    docker start "\${ACTIVE_GATEWAY}" >/dev/null 2>&1 || true
  fi
  for i in \$(seq 1 45); do
    if docker exec "\${ACTIVE_GATEWAY}" wget -q -T 2 -O /dev/null http://127.0.0.1:18080/health && \\
      docker exec gateway-caddy wget -q -T 2 -O /dev/null "http://\${ACTIVE_GATEWAY}:18080/health"; then
      active_ready=true
      break
    fi
    sleep 2
  done
  if [ "\${active_ready}" != true ]; then
    echo "WARN: active gateway did not recover; leaving candidate in service." >&2
    return 0
  fi
  if [ -f "\${backup}" ]; then
    cp "\${backup}" Caddyfile.1g
    if ! docker exec -i gateway-caddy sh -c 'cat > /tmp/Caddyfile.rollback && caddy reload --config /tmp/Caddyfile.rollback --adapter caddyfile' < Caddyfile.1g || \\
      ! docker exec gateway-caddy wget -q -O- http://127.0.0.1:2019/config/ | grep -q "\${ACTIVE_GATEWAY}:18080"; then
      echo "WARN: Caddy rollback failed; leaving candidate in service." >&2
      return 0
    fi
  fi
  docker rm -f "\${NEXT_GATEWAY}" >/dev/null 2>&1 || true
}
failed=true
cleanup() {
  status=\$?
  if [ "\${failed}" = true ]; then
    restore_active
  else
    rm -f "\${env_file}"
  fi
  exit "\${status}"
}
trap cleanup EXIT
chmod 600 "\${env_file}"
docker inspect "\${ACTIVE_GATEWAY}" --format '{{range .Config.Env}}{{println .}}{{end}}' > "\${env_file}"
set_env_override() {
  key="\$1"
  value="\$2"
  [ -n "\${value}" ] || return 0
  next_env="\${env_file}.next"
  awk -F= -v key="\${key}" '\$1 != key { print }' "\${env_file}" > "\${next_env}"
  printf '%s=%s\n' "\${key}" "\${value}" >> "\${next_env}"
  mv "\${next_env}" "\${env_file}"
}
set_env_override GOMAXPROCS "\${GATEWAY_GOMAXPROCS}"
set_env_override GOMEMLIMIT "\${GATEWAY_GOMEMLIMIT}"
set_env_override GATEWAY_STREAM_KEEPALIVE_INTERVAL "\${GATEWAY_STREAM_KEEPALIVE_INTERVAL}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}"
set_env_override GATEWAY_RESPONSES_MAX_BODY_SIZE "\${GATEWAY_RESPONSES_MAX_BODY_SIZE}"
docker rm -f "\${NEXT_GATEWAY}" >/dev/null 2>&1 || true
# During the short overlap the two gateway cgroup maxima remain below the
# 2GiB baseline. This candidate is deliberately live: stopping the active
# gateway first creates the observed Caddy 502/503 window.
docker run -d \\
  --name "\${NEXT_GATEWAY}" \\
  --restart unless-stopped \\
  --network gateway_gateway-network \\
  --ulimit nofile=65535:65535 \\
  --memory "\${CANARY_MEMORY_LIMIT}" \\
  --memory-swap "\${CANARY_MEMORY_LIMIT}" \\
  --env-file "\${env_file}" \\
  -v /opt/gateway/data:/app/data \\
  gateway:cloud >/dev/null
ready_streak=0
for i in \$(seq 1 45); do
  if docker exec "\${NEXT_GATEWAY}" wget -q -T 2 -O /dev/null http://127.0.0.1:18080/health; then
    ready_streak=\$((ready_streak + 1))
    [ "\${ready_streak}" -ge 3 ] && break
  else
    ready_streak=0
  fi
  sleep 2
done
test "\${ready_streak}" -ge 3
docker exec gateway-caddy wget -q -T 2 -O /dev/null "http://\${NEXT_GATEWAY}:18080/health"
mv Caddyfile.1g.next Caddyfile.1g
docker exec -i gateway-caddy sh -c 'cat > /tmp/Caddyfile.next && caddy reload --config /tmp/Caddyfile.next --adapter caddyfile' < Caddyfile.1g
docker exec gateway-caddy wget -q -O- http://127.0.0.1:2019/config/ | grep -q "\${NEXT_GATEWAY}:18080"
if [ "\${SERIAL_DRAIN_SECONDS}" -gt 0 ]; then
  sleep "\${SERIAL_DRAIN_SECONDS}"
fi
docker stop "\${ACTIVE_GATEWAY}" >/dev/null
docker update --memory "\${GATEWAY_MEMORY_LIMIT}" --memory-swap "\${GATEWAY_MEMORY_LIMIT}" "\${NEXT_GATEWAY}" >/dev/null
failed=false
echo "active=\${NEXT_GATEWAY}"
echo "rollback=\${ACTIVE_GATEWAY}"
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

apply_steady_state_resource_limits() {
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
docker update --memory 96m --memory-swap 96m gateway-caddy >/dev/null
docker update --memory 320m --memory-swap 320m gateway-postgres >/dev/null
docker update --memory 128m --memory-swap 128m gateway-redis >/dev/null
docker inspect gateway-caddy --format 'gateway-caddy memory={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}}'
docker inspect gateway-postgres --format 'gateway-postgres memory={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}}'
docker inspect gateway-redis --format 'gateway-redis memory={{.HostConfig.Memory}} swap={{.HostConfig.MemorySwap}}'
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

remote_current_gateway() {
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
grep -Eo 'reverse_proxy[[:space:]]+[^[:space:]]+:18080' Caddyfile.1g | awk '{print \$2}' | sed 's/:18080$//' | head -1
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

build_remote_image() {
  echo "Building production image from local HEAD..."
  ENV_FILE="${ENV_FILE}" \
    DEPLOY_MODE=build \
    BUILD_STRATEGY=local-binary \
    DOMAIN="${DOMAIN}" \
    TARGET_REGION="${TARGET_REGION}" \
    SSH_TARGET="${SSH_TARGET}" \
    SSH_PORT="${SSH_PORT:-}" \
    SSH_KEY="${SSH_KEY:-}" \
    SSH_BIND_ADDRESS="${SSH_BIND_ADDRESS:-}" \
    SSH_PASS="${SSH_PASSWORD:-}" \
    SUDO_PASSWORD="${SUDO_PASSWORD:-}" \
    REMOTE_DIR="${REMOTE_DIR}" \
    "${SCRIPT_DIR}/deploy-1g.sh"
}

promote_new_container() {
  local active_gateway="$1"
  local commit="$2"
  local next_gateway="$3"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
ACTIVE_GATEWAY=$(single_quote "${active_gateway}")
NEXT_GATEWAY=$(single_quote "${next_gateway}")
EXPECTED_REVISION=$(single_quote "${commit}")
GATEWAY_MEMORY_LIMIT=$(single_quote "${GATEWAY_MEMORY_LIMIT}")
GATEWAY_GOMAXPROCS=$(single_quote "${GATEWAY_GOMAXPROCS:-}")
GATEWAY_GOMEMLIMIT=$(single_quote "${GATEWAY_GOMEMLIMIT:-}")
GATEWAY_STREAM_KEEPALIVE_INTERVAL=$(single_quote "${GATEWAY_STREAM_KEEPALIVE_INTERVAL}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}")
GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS=$(single_quote "${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}")
GATEWAY_RESPONSES_MAX_BODY_SIZE=$(single_quote "${GATEWAY_RESPONSES_MAX_BODY_SIZE}")

image_revision="\$(docker inspect gateway:cloud --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
test "\${image_revision}" = "\${EXPECTED_REVISION}"
test "\${ACTIVE_GATEWAY}" != "\${NEXT_GATEWAY}"
test "\$(docker inspect "\${ACTIVE_GATEWAY}" --format '{{.State.Health.Status}}')" = healthy

docker rm -f "\${NEXT_GATEWAY}" >/dev/null 2>&1 || true
env_file="\$(mktemp /tmp/gateway-next-env.XXXXXX)"
chmod 600 "\${env_file}"
docker inspect "\${ACTIVE_GATEWAY}" --format '{{range .Config.Env}}{{println .}}{{end}}' > "\${env_file}"
set_env_override() {
  key="\$1"
  value="\$2"
  [ -n "\${value}" ] || return 0
  next_env="\${env_file}.next"
  awk -F= -v key="\${key}" '\$1 != key { print }' "\${env_file}" > "\${next_env}"
  printf '%s=%s\n' "\${key}" "\${value}" >> "\${next_env}"
  mv "\${next_env}" "\${env_file}"
}
set_env_override GOMAXPROCS "\${GATEWAY_GOMAXPROCS}"
set_env_override GOMEMLIMIT "\${GATEWAY_GOMEMLIMIT}"
set_env_override GATEWAY_STREAM_KEEPALIVE_INTERVAL "\${GATEWAY_STREAM_KEEPALIVE_INTERVAL}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}"
set_env_override GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS "\${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}"
set_env_override GATEWAY_RESPONSES_MAX_BODY_SIZE "\${GATEWAY_RESPONSES_MAX_BODY_SIZE}"
docker run -d \\
  --name "\${NEXT_GATEWAY}" \\
  --restart unless-stopped \\
  --network gateway_gateway-network \\
  --ulimit nofile=65535:65535 \\
  --memory "\${GATEWAY_MEMORY_LIMIT}" \\
  --env-file "\${env_file}" \\
  -v /opt/gateway/data:/app/data \\
  gateway:cloud >/dev/null
rm -f "\${env_file}"

for i in \$(seq 1 45); do
  status="\$(docker inspect "\${NEXT_GATEWAY}" --format '{{.State.Health.Status}}' 2>/dev/null || true)"
  [ "\${status}" = healthy ] && break
  sleep 2
done
test "\$(docker inspect "\${NEXT_GATEWAY}" --format '{{.State.Health.Status}}')" = healthy

backup="Caddyfile.1g.before-\${NEXT_GATEWAY}-\$(date -u +%Y%m%dT%H%M%SZ).bak"
cp Caddyfile.1g "\${backup}"
sed "s/reverse_proxy \${ACTIVE_GATEWAY}:18080/reverse_proxy \${NEXT_GATEWAY}:18080/" "\${backup}" > Caddyfile.1g

if docker ps --format '{{.Names}}' | grep -qx gateway-caddy; then
  docker exec -i gateway-caddy sh -c 'cat > /tmp/Caddyfile.next && caddy validate --config /tmp/Caddyfile.next --adapter caddyfile && caddy reload --config /tmp/Caddyfile.next --adapter caddyfile' < Caddyfile.1g
else
  docker start gateway-caddy >/dev/null
fi
docker exec gateway-caddy wget -q -O- http://127.0.0.1:2019/config/ | grep -q "\${NEXT_GATEWAY}:18080"
echo "active=\${ACTIVE_GATEWAY}"
echo "deployed=\${NEXT_GATEWAY}"
echo "revision=\${image_revision}"
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

switch_back() {
  local target="$1"
  echo "Verification failed. Switching Caddy back to ${target}..." >&2
  ROLLBACK_TARGET="${target}" ENV_FILE="${ENV_FILE}" DOMAIN="${DOMAIN}" REMOTE_DIR="${REMOTE_DIR}" TARGET_REGION="${TARGET_REGION}" \
    SSH_TARGET="${SSH_TARGET}" SSH_PORT="${SSH_PORT:-}" SSH_KEY="${SSH_KEY:-}" SSH_BIND_ADDRESS="${SSH_BIND_ADDRESS:-}" SSH_PASS="${SSH_PASSWORD:-}" SUDO_PASSWORD="${SUDO_PASSWORD:-}" \
    "${SCRIPT_DIR}/rollback.sh" to "${target}" >/dev/null || true
}

public_health_code() {
  if [ "${PUBLIC_VERIFICATION_SOURCE}" = remote ]; then
    run_ssh "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 $(single_quote "https://${DOMAIN}/health")"
  else
    curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 5 "https://${DOMAIN}/health"
  fi
}

public_login() {
  if [ "${PUBLIC_VERIFICATION_SOURCE}" = remote ]; then
    run_ssh "curl -fsS --connect-timeout 8 --max-time 20 $(single_quote "https://${DOMAIN}/login")"
  else
    curl -fsS --connect-timeout 8 --max-time 20 "https://${DOMAIN}/login"
  fi
}

public_responses_code() {
  if [ "${PUBLIC_VERIFICATION_SOURCE}" = remote ]; then
    run_ssh "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 -H 'Content-Type: application/json' -d '{\"model\":\"gpt-5\",\"input\":\"ping\"}' $(single_quote "https://${DOMAIN}/v1/responses")"
  else
    curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 8 --max-time 20 \
      -H 'Content-Type: application/json' \
      -d '{"model":"gpt-5","input":"ping"}' \
      "https://${DOMAIN}/v1/responses"
  fi
}

verify_public() {
  local active_gateway="$1"
  local fail=0
  local success=0
  local streak=0
  local max_streak=0
  local code
  for i in $(seq 1 "${HEALTH_ATTEMPTS}"); do
    code="$(public_health_code || echo curl_fail)"
    if [ "${code}" = 200 ]; then
      success=$((success + 1))
      streak=$((streak + 1))
      [ "${streak}" -gt "${max_streak}" ] && max_streak="${streak}"
    else
      echo "health check failed: try=${i} code=${code}" >&2
      fail=$((fail + 1))
      streak=0
    fi
    sleep "${HEALTH_SLEEP}"
  done
  if [ "${success}" -lt "${HEALTH_MIN_SUCCESS}" ] || [ "${max_streak}" -lt "${HEALTH_REQUIRED_STREAK}" ]; then
    switch_back "${active_gateway}"
    die "Public health loop was unstable: success=${success} fail=${fail} max_streak=${max_streak}."
  fi
  echo "Public health loop passed: success=${success} fail=${fail} max_streak=${max_streak}"

  public_login | grep -q '<div id="app"' || {
    switch_back "${active_gateway}"
    die "Login page did not render the frontend app."
  }

  code="$(public_responses_code || echo curl_fail)"
  case "${code}" in
    400|401|403) ;;
    *)
      switch_back "${active_gateway}"
      die "/v1/responses returned ${code}; expected auth/client error, not an origin failure."
      ;;
  esac
}

cleanup_old_gateways() {
  local deployed_gateway="$1"
  local rollback_gateway="$2"
  local keep_rollbacks="$3"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
DEPLOYED_GATEWAY=$(single_quote "${deployed_gateway}")
ROLLBACK_GATEWAY=$(single_quote "${rollback_gateway}")
KEEP_ROLLBACKS=$(single_quote "${keep_rollbacks}")

case "\${KEEP_ROLLBACKS}" in
  ''|*[!0-9]*) KEEP_ROLLBACKS=1 ;;
esac
if [ "\${KEEP_ROLLBACKS}" -lt 0 ]; then
  KEEP_ROLLBACKS=1
fi

keep_file="\$(mktemp /tmp/gateway-keep.XXXXXX)"
trap 'rm -f "\${keep_file}"' EXIT
printf '%s\n' "\${DEPLOYED_GATEWAY}" >> "\${keep_file}"
if [ "\${KEEP_ROLLBACKS}" -gt 0 ] && [ -n "\${ROLLBACK_GATEWAY}" ]; then
  printf '%s\n' "\${ROLLBACK_GATEWAY}" >> "\${keep_file}"
fi

docker ps -a --format '{{.Names}} {{.State}}' | grep -E '^(gateway$|gateway-(green|blue|next|rollback)) ' | while read -r name state; do
  if grep -Fxq "\${name}" "\${keep_file}"; then
    echo "keep gateway container: \${name}"
    continue
  fi
  if [ "\${state}" = running ]; then
    echo "stop old gateway container: \${name}"
    docker stop "\${name}" >/dev/null || true
  fi
  echo "remove stale gateway container: \${name}"
  docker rm "\${name}" >/dev/null || true
done
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
  fi
  [ "$#" -eq 0 ] || die "Unknown argument: $*"
  need awk
  need curl
  need git
  need sed
  load_connection_defaults
  validate_runtime_overrides
  require_clean_head
  acquire_deploy_lock

  local commit active_gateway deploy_strategy deployed_gateway
  commit="$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD)"
  # A configuration-only rollout can use the same image revision as the
  # currently active gateway.  The container name must still be unique: on a
  # 2GiB serial cutover, reusing the active name would delete the only serving
  # container before its replacement is ready.
  deployed_gateway="gateway-green-${commit}-$(date -u +%Y%m%d%H%M%S)-$$"
  active_gateway="$(remote_current_gateway)"
  [ -n "${active_gateway}" ] || die "Could not determine active Caddy upstream."
  deploy_strategy="$(select_deploy_strategy)"
  echo "Current production gateway: ${active_gateway}"
  echo "Deploying revision: ${commit}"
  echo "Deployment strategy: ${deploy_strategy}"
  echo "Gateway runtime memory limit: ${GATEWAY_MEMORY_LIMIT}"
  [ -n "${GATEWAY_GOMAXPROCS:-}" ] && echo "Gateway runtime GOMAXPROCS: ${GATEWAY_GOMAXPROCS}"
  [ -n "${GATEWAY_GOMEMLIMIT:-}" ] && echo "Gateway runtime GOMEMLIMIT: ${GATEWAY_GOMEMLIMIT}"
  echo "Gateway stream keepalive interval: ${GATEWAY_STREAM_KEEPALIVE_INTERVAL}s"
  echo "Gateway stream governance: enabled=${GATEWAY_OPENAI_STREAM_GOVERNANCE_ENABLED} rollout=${GATEWAY_OPENAI_STREAM_GOVERNANCE_ROLLOUT_PERCENT}% total=${GATEWAY_OPENAI_STREAM_GOVERNANCE_TOTAL_BUDGET_SECONDS}s first=${GATEWAY_OPENAI_STREAM_GOVERNANCE_FIRST_ATTEMPT_BUDGET_SECONDS}s"
  echo "Gateway responses body budget: ${GATEWAY_RESPONSES_MAX_BODY_SIZE:-inherited} bytes"
  echo "Public verification source: ${PUBLIC_VERIFICATION_SOURCE}"

  build_remote_image
  local current_gateway
  current_gateway="$(remote_current_gateway)"
  if [ "${current_gateway}" != "${active_gateway}" ]; then
    die "Caddy upstream changed while the image was building (${active_gateway} -> ${current_gateway}); refusing a stale cutover. Wait for the other deployment to finish, then retry."
  fi
  case "${deploy_strategy}" in
    bluegreen)
      promote_new_container "${active_gateway}" "${commit}" "${deployed_gateway}"
      ;;
    serial)
      echo "2GiB-safe serial mode: stopping inactive rollback containers before candidate preflight."
      stop_inactive_gateways "${active_gateway}"
      start_serial_candidate "${active_gateway}" "${commit}"
      promote_serial_candidate "${active_gateway}" "${commit}" "${deployed_gateway}"
      ;;
    *) die "Unexpected deployment strategy: ${deploy_strategy}" ;;
  esac
  apply_steady_state_resource_limits
  verify_public "${active_gateway}"
  # Stale-container pruning is housekeeping, not a correctness gate.  Once
  # Caddy, the new gateway and public probes are verified, an inability to
  # remove an already-stopped historical container must not report the whole
  # deploy as failed or trigger an unnecessary recovery action.
  if ! cleanup_old_gateways "${deployed_gateway}" "${active_gateway}" "${KEEP_ROLLBACKS}"; then
    echo "WARN: deployment is healthy, but stale gateway cleanup did not complete." >&2
  fi

  echo "Deploy complete: ${deployed_gateway}"
  echo "Rollback command: deploy/rollback.sh to ${active_gateway}"
}

main "$@"
