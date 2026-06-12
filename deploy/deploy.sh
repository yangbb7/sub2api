#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/deploy"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy-1g.env.local}"
DOMAIN="${DOMAIN:-api.braintech.icu}"
REMOTE_DIR="${REMOTE_DIR:-/opt/gateway}"
TARGET_REGION="${TARGET_REGION:-jp}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-15}"
HEALTH_ATTEMPTS="${HEALTH_ATTEMPTS:-60}"
HEALTH_SLEEP="${HEALTH_SLEEP:-0.2}"

usage() {
  cat <<'EOF'
Usage:
  deploy/deploy.sh

What it does:
  1. Requires local HEAD to match origin/main unless ALLOW_UNPUSHED=1.
  2. Builds the embedded frontend and linux gateway binary locally.
  3. Builds gateway:cloud on the production server.
  4. Starts a new parallel gateway container from the active container env.
  5. Hot-reloads Caddy to the new container after health checks pass.

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
    SSH_PASS="${SSH_PASSWORD:-}" \
    SUDO_PASSWORD="${SUDO_PASSWORD:-}" \
    REMOTE_DIR="${REMOTE_DIR}" \
    "${SCRIPT_DIR}/deploy-1g.sh"
}

promote_new_container() {
  local active_gateway="$1"
  local commit="$2"
  local next_gateway="gateway-green-${commit}"
  local tmp
  tmp="$(mktemp)"
  cat > "${tmp}" <<REMOTE
#!/usr/bin/env bash
set -euo pipefail
cd $(single_quote "${REMOTE_DIR}")
ACTIVE_GATEWAY=$(single_quote "${active_gateway}")
NEXT_GATEWAY=$(single_quote "${next_gateway}")
EXPECTED_REVISION=$(single_quote "${commit}")

image_revision="\$(docker inspect gateway:cloud --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
test "\${image_revision}" = "\${EXPECTED_REVISION}"
test "\${ACTIVE_GATEWAY}" != "\${NEXT_GATEWAY}"
test "\$(docker inspect "\${ACTIVE_GATEWAY}" --format '{{.State.Health.Status}}')" = healthy

docker rm -f "\${NEXT_GATEWAY}" >/dev/null 2>&1 || true
env_file="\$(mktemp /tmp/gateway-next-env.XXXXXX)"
chmod 600 "\${env_file}"
docker inspect "\${ACTIVE_GATEWAY}" --format '{{range .Config.Env}}{{println .}}{{end}}' > "\${env_file}"
docker run -d \\
  --name "\${NEXT_GATEWAY}" \\
  --restart unless-stopped \\
  --network gateway_gateway-network \\
  --ulimit nofile=65535:65535 \\
  --memory 256m \\
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
    SSH_TARGET="${SSH_TARGET}" SSH_PORT="${SSH_PORT:-}" SSH_KEY="${SSH_KEY:-}" SSH_PASS="${SSH_PASSWORD:-}" SUDO_PASSWORD="${SUDO_PASSWORD:-}" \
    "${SCRIPT_DIR}/rollback.sh" to "${target}" >/dev/null || true
}

verify_public() {
  local active_gateway="$1"
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
  if [ "${fail}" -ne 0 ]; then
    switch_back "${active_gateway}"
    die "Public health loop failed ${fail} time(s)."
  fi

  curl -fsS --connect-timeout 8 --max-time 20 "https://${DOMAIN}/login" | grep -q '<div id="app"' || {
    switch_back "${active_gateway}"
    die "Login page did not render the frontend app."
  }

  code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 8 --max-time 20 \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5","input":"ping"}' \
    "https://${DOMAIN}/v1/responses" || echo curl_fail)"
  case "${code}" in
    400|401|403) ;;
    *)
      switch_back "${active_gateway}"
      die "/v1/responses returned ${code}; expected auth/client error, not an origin failure."
      ;;
  esac
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
  require_clean_head

  local commit active_gateway
  commit="$(git -C "${ROOT_DIR}" rev-parse --short=12 HEAD)"
  active_gateway="$(remote_current_gateway)"
  [ -n "${active_gateway}" ] || die "Could not determine active Caddy upstream."
  echo "Current production gateway: ${active_gateway}"
  echo "Deploying revision: ${commit}"

  build_remote_image
  promote_new_container "${active_gateway}" "${commit}"
  verify_public "${active_gateway}"

  echo "Deploy complete: gateway-green-${commit}"
  echo "Rollback command: deploy/rollback.sh to ${active_gateway}"
}

main "$@"
