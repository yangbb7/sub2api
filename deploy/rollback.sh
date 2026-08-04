#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy-1g.env.local}"
DOMAIN="${DOMAIN:-api.braintech.icu}"
REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
TARGET_REGION="${TARGET_REGION:-jp}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-40}"
HEALTH_SLEEP="${HEALTH_SLEEP:-0.2}"

usage() {
  cat <<'EOF'
Usage:
  deploy/rollback.sh
  deploy/rollback.sh previous
  deploy/rollback.sh list
  deploy/rollback.sh to [gateway-container]

Default:
  No arguments means "previous".

What it does:
  Switches Caddy to an already-running healthy gateway container.
  It does not build, recreate compose services, rewrite .env, touch DNS, or touch the database.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
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
    TARGET_REGION DOMAIN REMOTE_DIR SSH_TARGET SSH_PORT SSH_KEY SSH_PASSWORD SSH_PASS SUDO_PASSWORD \
    JP_SSH_TARGET JP_SSH_PORT JP_SSH_KEY JP_SSH_PASSWORD JP_SSH_PASS \
    HK_SSH_TARGET HK_SSH_PORT HK_SSH_KEY HK_SSH_PASSWORD HK_SSH_PASS
  do
    default_from_env_file "${name}"
  done

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
  local remote_script="/tmp/sub2api-rollback-$(date -u +%Y%m%dT%H%M%SZ)-$$.sh"
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

list_targets() {
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
current="\$(grep -Eo 'reverse_proxy[[:space:]]+[^[:space:]]+:18080' Caddyfile.1g | awk '{print \$2}' | sed 's/:18080$//' | head -1 || true)"
printf 'CURRENT %s\\n' "\${current:-unknown}"
docker ps -a --format '{{.Names}}' | grep -E '^(gateway$|gateway-(green|blue|next|rollback))' | while read -r name; do
  state="\$(docker inspect "\${name}" --format '{{.State.Status}}')"
  health="\$(docker inspect "\${name}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  revision="\$(docker inspect "\${name}" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  created="\$(docker inspect "\${name}" --format '{{.Created}}')"
  marker=' '
  [ "\${name}" = "\${current}" ] && marker='*'
  printf '%s\t%s\t%s\t%s\t%s\t%s\\n' "\${created}" "\${marker}" "\${name}" "\${state}" "\${health}" "\${revision:-unknown}"
done | sort -r | awk -F '\\t' '{printf "%s %s %s %s/%s %s\\n", \$2, \$1, \$3, \$4, \$5, \$6}'
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

select_previous_target() {
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
current="\$(grep -Eo 'reverse_proxy[[:space:]]+[^[:space:]]+:18080' Caddyfile.1g | awk '{print \$2}' | sed 's/:18080$//' | head -1 || true)"
docker ps -a --format '{{.Names}}' | grep -E '^(gateway$|gateway-(green|blue|next|rollback))' | while read -r name; do
  [ "\${name}" != "\${current}" ] || continue
  state="\$(docker inspect "\${name}" --format '{{.State.Status}}')"
  health="\$(docker inspect "\${name}" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')"
  if [ "\${state}" = running ]; then
    [ "\${health}" = healthy ] || continue
  else
    [ "\${state}" = exited ] || continue
  fi
  created="\$(docker inspect "\${name}" --format '{{.Created}}')"
  printf '%s %s\\n' "\${created}" "\${name}"
done | sort -r | awk 'NR == 1 {print \$2}'
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

switch_caddy() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
TARGET=$(single_quote "${target}")
current="\$(grep -Eo 'reverse_proxy[[:space:]]+[^[:space:]]+:18080' Caddyfile.1g | awk '{print \$2}' | sed 's/:18080$//' | head -1 || true)"
test -n "\${current}"
if [ "\${current}" = "\${TARGET}" ]; then
  echo "already=\${TARGET}"
  exit 0
fi
target_was_stopped=false
target_state="\$(docker inspect "\${TARGET}" --format '{{.State.Status}}')"
restore_current() {
  docker stop "\${TARGET}" >/dev/null 2>&1 || true
  docker start "\${current}" >/dev/null 2>&1 || true
}
if [ "\${target_state}" != running ]; then
  [ "\${target_state}" = exited ] || {
    echo "rollback target is not runnable: \${TARGET} state=\${target_state}" >&2
    exit 1
  }
  # Serial deployments keep the old container stopped to fit in 2GiB. Do not
  # briefly run both full-size gateways when restoring it.
  docker stop "\${current}" >/dev/null
  if ! docker start "\${TARGET}" >/dev/null; then
    docker start "\${current}" >/dev/null 2>&1 || true
    exit 1
  fi
  target_was_stopped=true
fi
ready=false
for i in \$(seq 1 45); do
  if docker exec "\${TARGET}" wget -q -T 2 -O /dev/null http://127.0.0.1:18080/health; then
    ready=true
    break
  fi
  sleep 2
done
if [ "\${ready}" != true ]; then
  [ "\${target_was_stopped}" = true ] && restore_current
  echo "rollback target did not become ready: \${TARGET}" >&2
  exit 1
fi
backup="Caddyfile.1g.before-rollback-to-\${TARGET}-\$(date -u +%Y%m%dT%H%M%SZ).bak"
cp Caddyfile.1g "\${backup}"
sed "s/reverse_proxy \${current}:18080/reverse_proxy \${TARGET}:18080/" "\${backup}" > Caddyfile.1g.next
if docker ps --format '{{.Names}}' | grep -qx gateway-caddy; then
  if ! docker exec -i gateway-caddy sh -c 'cat > /tmp/Caddyfile.next && caddy validate --config /tmp/Caddyfile.next --adapter caddyfile' < Caddyfile.1g.next || \\
    ! mv Caddyfile.1g.next Caddyfile.1g || \\
    ! docker exec -i gateway-caddy sh -c 'cat > /tmp/Caddyfile.next && caddy reload --config /tmp/Caddyfile.next --adapter caddyfile' < Caddyfile.1g; then
    cp "\${backup}" Caddyfile.1g
    docker exec -i gateway-caddy sh -c 'cat > /tmp/Caddyfile.rollback && caddy reload --config /tmp/Caddyfile.rollback --adapter caddyfile' < Caddyfile.1g || true
    [ "\${target_was_stopped}" = true ] && restore_current
    exit 1
  fi
else
  mv Caddyfile.1g.next Caddyfile.1g
  docker start gateway-caddy >/dev/null
fi
docker exec gateway-caddy wget -q -O- http://127.0.0.1:2019/config/ | grep -q "\${TARGET}:18080"
revision="\$(docker inspect "\${TARGET}" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
echo "previous=\${current}"
echo "active=\${TARGET}"
echo "revision=\${revision:-unknown}"
REMOTE
  run_remote_root_script "${tmp}"
  rm -f "${tmp}"
}

verify_public() {
  local fail=0
  local code
  for i in $(seq 1 "${HEALTH_ATTEMPTS}"); do
    code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time 5 "https://${DOMAIN}/health" || echo curl_fail)"
    if [ "${code}" != 200 ]; then
      echo "health check failed: try=${i} code=${code}" >&2
      fail=$((fail + 1))
    fi
    sleep "${HEALTH_SLEEP}"
  done
  [ "${fail}" -eq 0 ] || die "Public health loop failed ${fail} time(s)."

  code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 8 --max-time 20 \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5","input":"ping"}' \
    "https://${DOMAIN}/v1/responses" || echo curl_fail)"
  case "${code}" in
    400|401|403) ;;
    *) die "/v1/responses returned ${code}; expected auth/client error, not an origin failure." ;;
  esac
}

main() {
  local command="${1:-previous}"
  local target
  case "${command}" in
    -h|--help)
      usage
      exit 0
      ;;
    list|previous|to) ;;
    *) die "Unknown command: ${command}" ;;
  esac

  need awk
  need curl
  need sed
  load_connection_defaults

  case "${command}" in
    list)
      list_targets
      ;;
    previous)
      target="$(select_previous_target)"
      [ -n "${target}" ] || die "No previous healthy gateway container found."
      echo "Rolling back to previous healthy gateway: ${target}"
      switch_caddy "${target}"
      verify_public
      echo "Rollback complete: ${target}"
      ;;
    to)
      target="${2:-${ROLLBACK_TARGET:-}}"
      [ -n "${target}" ] || die "Usage: deploy/rollback.sh to [gateway-container]"
      echo "Rolling back to gateway: ${target}"
      switch_caddy "${target}"
      verify_public
      echo "Rollback complete: ${target}"
      ;;
  esac
}

main "$@"
