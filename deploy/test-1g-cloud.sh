#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ROOT_DIR}/deploy"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need bash
need sh
need tar
need gzip
need awk

echo "Checking shell syntax..."
bash -n \
  "${DEPLOY_DIR}/deploy-1g.sh" \
  "${DEPLOY_DIR}/deploy.sh" \
  "${DEPLOY_DIR}/rollback.sh" \
  "${DEPLOY_DIR}/doctor-1g.sh" \
  "${DEPLOY_DIR}/check-1g.sh" \
  "${DEPLOY_DIR}/restore-1g-config.sh" \
  "${DEPLOY_DIR}/init-huana-1g-env.sh" \
  "${DEPLOY_DIR}/huana-1g-deploy.sh" \
  "${DEPLOY_DIR}/ready-1g.sh" \
  "${DEPLOY_DIR}/verify-live-1g.sh" \
  "${DEPLOY_DIR}/audit-1g-completion.sh" \
  "${DEPLOY_DIR}/cloudflare-upsert-dns.sh" \
	"${DEPLOY_DIR}/stream-isolation-probe.sh" \
  "${DEPLOY_DIR}/test-doctor-1g.sh" \
  "${DEPLOY_DIR}/test-upload-deadline.sh" \
  "${DEPLOY_DIR}/test-cloudflare-upsert-dns.sh" \
  "${DEPLOY_DIR}/test-simple-prod-scripts.sh" \
  "${DEPLOY_DIR}/test-probe-frontend.sh" \
  "${DEPLOY_DIR}/test-remote-1g-preflight.sh" \
  "${DEPLOY_DIR}/test-remote-1g-bootstrap.sh" \
  "${DEPLOY_DIR}/test-1g-cloud.sh" \
  "${DEPLOY_DIR}/remote-1g-bootstrap.sh"
sh -n \
  "${DEPLOY_DIR}/probe-frontend.sh" \
  "${DEPLOY_DIR}/remote-1g-preflight.sh"

echo "Checking Huana env initializer..."
tmp_env="$(mktemp)"
rm -f "${tmp_env}"
SSH_PASS=secret_ssh_password \
CF_API_TOKEN=secret_cloudflare_token \
DOMAIN=api.example.net \
JP_SSH_TARGET=dhy@203.0.113.20 \
JP_TARGET_IP=203.0.113.20 \
HK_SSH_TARGET=dhy@203.0.113.21 \
HK_TARGET_IP=203.0.113.21 \
ENV_FILE="${tmp_env}" \
  "${DEPLOY_DIR}/init-huana-1g-env.sh" >/dev/null
if ! grep -q '^JP_SSH_TARGET=dhy@203\.0\.113\.20$' "${tmp_env}" ||
  ! grep -q '^JP_TARGET_IP=203\.0\.113\.20$' "${tmp_env}" ||
  ! grep -q '^HK_SSH_TARGET=dhy@203\.0\.113\.21$' "${tmp_env}" ||
  ! grep -q '^HK_TARGET_IP=203\.0\.113\.21$' "${tmp_env}" ||
  ! grep -q '^DOMAIN=api\.example\.net$' "${tmp_env}" ||
  grep -q 'secret_ssh_password\|secret_cloudflare_token' "${tmp_env}"; then
  echo "Huana env initializer wrote incorrect or unsafe content" >&2
  exit 1
fi
env_mode="$(stat -f %Lp "${tmp_env}" 2>/dev/null || stat -c %a "${tmp_env}" 2>/dev/null)"
case "${env_mode}" in
  600|400) ;;
  *)
    echo "Huana env initializer created unsafe permissions: ${env_mode}" >&2
    exit 1
    ;;
esac
rm -f "${tmp_env}"

echo "Checking 1G deploy readiness gate..."
tmp_env="$(mktemp)"
rm -f "${tmp_env}"
DOMAIN=api.example.net \
JP_SSH_TARGET=dhy@203.0.113.20 \
JP_TARGET_IP=203.0.113.20 \
HK_SSH_TARGET=dhy@203.0.113.21 \
HK_TARGET_IP=203.0.113.21 \
ENV_FILE="${tmp_env}" "${DEPLOY_DIR}/init-huana-1g-env.sh" >/dev/null
SSH_PASS=secret_ssh_password CF_API_TOKEN=secret_cloudflare_token ENV_FILE="${tmp_env}" \
  "${DEPLOY_DIR}/ready-1g.sh" >/dev/null
if SSH_PASS=secret_ssh_password ENV_FILE="${tmp_env}" "${DEPLOY_DIR}/ready-1g.sh" >/dev/null 2>&1; then
  echo "ready-1g.sh accepted a missing Cloudflare token" >&2
  exit 1
fi
printf 'SSH_PASS=bad_persisted_secret\n' >> "${tmp_env}"
if SSH_PASS=secret_ssh_password CF_API_TOKEN=secret_cloudflare_token ENV_FILE="${tmp_env}" "${DEPLOY_DIR}/ready-1g.sh" >/dev/null 2>&1; then
  echo "ready-1g.sh accepted a persisted SSH secret" >&2
  exit 1
fi
sed '/^SSH_PASS=bad_persisted_secret$/d' "${tmp_env}" > "${tmp_env}.next"
mv "${tmp_env}.next" "${tmp_env}"
printf 'SUDO_PASSWORD=bad_persisted_sudo_secret\n' >> "${tmp_env}"
if SSH_PASS=secret_ssh_password CF_API_TOKEN=secret_cloudflare_token ENV_FILE="${tmp_env}" "${DEPLOY_DIR}/ready-1g.sh" >/dev/null 2>&1; then
  echo "ready-1g.sh accepted a persisted sudo password" >&2
  exit 1
fi
rm -f "${tmp_env}"

echo "Checking live verification selector..."
tmp_verify_dir="$(mktemp -d)"
tmp_env="${tmp_verify_dir}/deploy.env"
cat > "${tmp_env}" <<'EOF'
TARGET_REGION=auto
DOMAIN=api.example.net
PROXIED=false
JP_TARGET_IP=203.0.113.20
HK_TARGET_IP=203.0.113.21
EOF
chmod 600 "${tmp_env}"
cat > "${tmp_verify_dir}/ready.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
test -n "${ENV_FILE:-}"
EOF
cat > "${tmp_verify_dir}/dns.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
test "${CHECK_ONLY}" = "true"
test "${DOMAIN}" = "api.example.net"
test "${PROXIED}" = "false"
test -n "${CF_API_TOKEN}"
test "${TARGET_IP}" = "203.0.113.21"
EOF
cat > "${tmp_verify_dir}/check.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
test "${TARGET_IP}" = "203.0.113.21"
test -n "${ENV_FILE:-}"
EOF
chmod +x "${tmp_verify_dir}/ready.sh" "${tmp_verify_dir}/dns.sh" "${tmp_verify_dir}/check.sh"
live_report="${tmp_verify_dir}/live-report.json"
SSH_PASS=secret_ssh_password \
CF_API_TOKEN=secret_cloudflare_token \
ENV_FILE="${tmp_env}" \
VERIFY_READY_SCRIPT="${tmp_verify_dir}/ready.sh" \
VERIFY_DNS_SCRIPT="${tmp_verify_dir}/dns.sh" \
VERIFY_CHECK_SCRIPT="${tmp_verify_dir}/check.sh" \
LIVE_REPORT_FILE="${live_report}" \
  "${DEPLOY_DIR}/verify-live-1g.sh" >/dev/null
python3 - "${live_report}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    report = json.load(fh)
assert report["domain"] == "api.example.net"
assert report["target_ip"] == "203.0.113.21"
assert report["proxied"] is False
assert "https_health_login_and_frontend_asset" in report["checks"]
PY
report_mode="$(stat -f %Lp "${live_report}" 2>/dev/null || stat -c %a "${live_report}" 2>/dev/null)"
case "${report_mode}" in
  600|400) ;;
  *)
    echo "live verification report permissions are unsafe: ${report_mode}" >&2
    exit 1
    ;;
esac
rm -rf "${tmp_verify_dir}"

echo "Checking completion audit gate..."
tmp_audit_dir="$(mktemp -d)"
tmp_env="${tmp_audit_dir}/deploy.env"
cat > "${tmp_env}" <<'EOF'
TARGET_REGION=auto
DOMAIN=api.example.net
PROXIED=false
JP_TARGET_IP=203.0.113.20
HK_TARGET_IP=203.0.113.21
EOF
chmod 600 "${tmp_env}"
if ENV_FILE="${tmp_env}" LIVE_REPORT_FILE="${tmp_audit_dir}/missing-report.json" \
  "${DEPLOY_DIR}/audit-1g-completion.sh" >/dev/null 2>&1; then
  echo "audit-1g-completion.sh accepted a missing live report" >&2
  exit 1
fi
bad_report="${tmp_audit_dir}/bad-report.json"
cat > "${bad_report}" <<'EOF'
{
  "checks": ["local_readiness"],
  "domain": "api.example.net",
  "proxied": false,
  "target_ip": "203.0.113.21",
  "verified_at_utc": "2026-05-16T00:00:00+00:00"
}
EOF
chmod 600 "${bad_report}"
if ENV_FILE="${tmp_env}" LIVE_REPORT_FILE="${bad_report}" \
  "${DEPLOY_DIR}/audit-1g-completion.sh" >/dev/null 2>&1; then
  echo "audit-1g-completion.sh accepted incomplete evidence" >&2
  exit 1
fi
good_report="${tmp_audit_dir}/good-report.json"
cat > "${good_report}" <<'EOF'
{
  "checks": [
    "local_readiness",
    "cloudflare_a_record_target",
    "cloudflare_proxied_state",
    "remote_compose_and_localhost",
    "https_health_login_and_frontend_asset"
  ],
  "domain": "api.example.net",
  "proxied": false,
  "target_ip": "203.0.113.21",
  "verified_at_utc": "2026-05-16T00:00:00+00:00"
}
EOF
chmod 600 "${good_report}"
ENV_FILE="${tmp_env}" LIVE_REPORT_FILE="${good_report}" \
  "${DEPLOY_DIR}/audit-1g-completion.sh" >/dev/null
printf 'CF_API_TOKEN=bad_persisted_secret\n' >> "${tmp_env}"
if ENV_FILE="${tmp_env}" LIVE_REPORT_FILE="${good_report}" \
  "${DEPLOY_DIR}/audit-1g-completion.sh" >/dev/null 2>&1; then
  echo "audit-1g-completion.sh accepted a persisted Cloudflare token" >&2
  exit 1
fi
rm -rf "${tmp_audit_dir}"

echo "Checking 1G Caddy log limits..."
if ! grep -q 'roll_size 10mb' "${DEPLOY_DIR}/Caddyfile.1g" ||
  ! grep -q 'roll_keep 3' "${DEPLOY_DIR}/Caddyfile.1g"; then
  echo "Caddyfile.1g must keep Caddy file logs capped for 1G VPS disks" >&2
  exit 1
fi

echo "Checking protected stream isolation probe..."
if ! grep -Fq 'ORIGIN_PROBE_MTLS_REQUIRED' "${DEPLOY_DIR}/stream-isolation-probe.sh" ||
  ! grep -Fq 'X-Request-ID:' "${DEPLOY_DIR}/stream-isolation-probe.sh" ||
  ! grep -Fq 'synthetic stream isolation probe' "${DEPLOY_DIR}/stream-isolation-probe.sh"; then
  echo "stream-isolation-probe.sh must use synthetic requests with mTLS-protected origin correlation" >&2
  exit 1
fi

echo "Checking 2C2G streaming compose baseline..."
compose_file="${DEPLOY_DIR}/docker-compose.1g.yml"
for expected in 'mem_limit: 96m' 'mem_limit: 896m' 'mem_limit: 320m' 'mem_limit: 128m' 'GOMAXPROCS=${GOMAXPROCS:-2}' 'GOMEMLIMIT=${GOMEMLIMIT:-640MiB}' '127.0.0.1:${SERVER_PORT:-18080}:18080' '80:80' '443:443'; do
  if ! grep -Fq "${expected}" "${compose_file}"; then
    echo "docker-compose.1g.yml is missing expected 2C2G baseline: ${expected}" >&2
    exit 1
  fi
done
if ! grep -Fq 'redis-cli -a' "${compose_file}" ||
  ! grep -Fq 'redis-cli ping' "${compose_file}"; then
  echo "docker-compose.1g.yml Redis healthcheck must explicitly handle password and no-password modes" >&2
  exit 1
fi

echo "Checking Dockerfile frontend embed path..."
if ! grep -Fq "outDir: '../backend/internal/web/dist'" "${ROOT_DIR}/frontend/vite.config.ts"; then
  echo "frontend/vite.config.ts must build assets into backend/internal/web/dist for embedded backend builds" >&2
  exit 1
fi
if ! grep -Fq 'RUN test -f ./internal/web/dist/index.html' "${DEPLOY_DIR}/Dockerfile.prebuilt"; then
  echo "deploy/Dockerfile.prebuilt must require prebuilt embedded frontend assets" >&2
  exit 1
fi
if ! grep -Fq 'COPY build/gateway /app/gateway' "${DEPLOY_DIR}/Dockerfile.binary"; then
  echo "deploy/Dockerfile.binary must copy the locally built gateway binary" >&2
  exit 1
fi
if ! grep -Fq 'ARG NODE_OPTIONS' "${DEPLOY_DIR}/Dockerfile.binary" ||
  ! grep -Fq 'ARG COMMIT=docker' "${DEPLOY_DIR}/Dockerfile.binary" ||
  ! grep -Fq 'org.opencontainers.image.revision="${COMMIT}"' "${DEPLOY_DIR}/Dockerfile.binary"; then
  echo "deploy/Dockerfile.binary must consume shared remote build args without warnings" >&2
  exit 1
fi
if ! grep -Fq 'BUILD_STRATEGY="${BUILD_STRATEGY:-local-binary}"' "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must default 1G deployments to local binary builds" >&2
  exit 1
fi
if ! grep -Fq 'ensure_clean_git_tree_for_local_binary' "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must require a clean worktree before local binary deployments" >&2
  exit 1
fi
if ! grep -Fq 'local-binary|remote' "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must validate local-binary and remote build strategies" >&2
  exit 1
fi
if ! grep -Fq 'GOOS="${target_goos}" GOARCH="${target_goarch}"' "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must cross-compile the gateway binary for the selected platform" >&2
  exit 1
fi
if ! grep -Fq 'COPY --from=frontend-builder /app/backend/internal/web/dist ./internal/web/dist' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must copy the Vite output from frontend-builder into backend/internal/web/dist" >&2
  exit 1
fi
if ! grep -Fq 'go build \' "${DEPLOY_DIR}/Dockerfile" ||
  ! grep -Fq -- '-tags embed' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must build the backend with -tags embed" >&2
  exit 1
fi

echo "Checking Dockerfile toolchain versions..."
go_mod_version="$(awk '$1 == "go" {print $2; exit}' "${ROOT_DIR}/backend/go.mod")"
docker_go_version="$(awk -F= '$1 == "ARG GOLANG_IMAGE" {value=$2; sub(/^golang:/, "", value); sub(/-alpine$/, "", value); print value; exit}' "${DEPLOY_DIR}/Dockerfile")"
if [ -z "${go_mod_version}" ] || [ "${docker_go_version}" != "${go_mod_version}" ]; then
  echo "deploy/Dockerfile GOLANG_IMAGE must match backend/go.mod go version (${go_mod_version:-missing})" >&2
  exit 1
fi
pnpm_version="$(awk -F= '$1 == "ARG PNPM_VERSION" {print $2; exit}' "${DEPLOY_DIR}/Dockerfile")"
lockfile_major="$(awk -F"'" '$1 ~ /^lockfileVersion:/ {split($2, parts, "."); print parts[1]; exit}' "${ROOT_DIR}/frontend/pnpm-lock.yaml")"
pnpm_major="${pnpm_version%%.*}"
if [ -z "${pnpm_major}" ] || [ "${pnpm_major}" != "${lockfile_major}" ]; then
  echo "deploy/Dockerfile PNPM_VERSION major must match frontend/pnpm-lock.yaml lockfileVersion major" >&2
  exit 1
fi
if ! grep -Fq 'pnpm config set fetch-retries 5' "${DEPLOY_DIR}/Dockerfile" ||
  ! grep -Fq 'pnpm config set network-timeout 600000' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must configure pnpm retries and timeout for small VPS network instability" >&2
  exit 1
fi
if ! grep -Fq -- "--build-arg PNPM_REGISTRY='" "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must pass PNPM_REGISTRY through to the remote Docker build" >&2
  exit 1
fi
if ! grep -Fq -- "--build-arg COMMIT='" "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must pass the local commit through to the remote Docker build" >&2
  exit 1
fi
if ! grep -Fq -- "--build-arg DATE='" "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must pass the local build date through to the remote Docker build" >&2
  exit 1
fi
if ! grep -Fq -- "-f '\${REMOTE_DOCKERFILE}'" "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must support selecting the remote Dockerfile" >&2
  exit 1
fi
if ! grep -Fq 'DOCKER_BUILDKIT=0 docker build' "${DEPLOY_DIR}/deploy-1g.sh"; then
  echo "deploy-1g.sh must disable BuildKit for lower-memory sequential remote builds" >&2
  exit 1
fi
if ! grep -Fq 'ARG NODE_OPTIONS=--max-old-space-size=1280' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must give the frontend build enough heap for the current app" >&2
  exit 1
fi
if grep -Fq 'ENV NODE_OPTIONS=' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must not let NODE_OPTIONS invalidate the pnpm install cache layer" >&2
  exit 1
fi
if ! grep -Fq 'RUN VITE_DISABLE_CHECKER=true NODE_OPTIONS="${NODE_OPTIONS}" pnpm exec vite build' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must scope NODE_OPTIONS to the frontend Vite build step" >&2
  exit 1
fi
if grep -Fq 'RUN NODE_OPTIONS="${NODE_OPTIONS}" pnpm run build' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must not run vue-tsc inside the 1G remote image build" >&2
  exit 1
fi
if ! grep -Fq "command === 'build'" "${ROOT_DIR}/frontend/vite.config.ts" ||
  ! grep -Fq 'process.env.VITE_DISABLE_CHECKER' "${ROOT_DIR}/frontend/vite.config.ts" ||
  ! grep -Fq 'plugins.push(checker({ vueTsc: true }))' "${ROOT_DIR}/frontend/vite.config.ts"; then
  echo "frontend/vite.config.ts must allow the 1G Docker build to disable vite-plugin-checker" >&2
  exit 1
fi
if ! grep -Fq 'ARG BUILD_GOMEMLIMIT=640MiB' "${DEPLOY_DIR}/Dockerfile" ||
  ! grep -Fq 'ARG BUILD_GCFLAGS=all=-l' "${DEPLOY_DIR}/Dockerfile" ||
  ! grep -Fq 'GOGC=50 go build' "${DEPLOY_DIR}/Dockerfile" ||
  ! grep -Fq -- '-p 1' "${DEPLOY_DIR}/Dockerfile" ||
  ! grep -Fq -- '-gcflags="${BUILD_GCFLAGS}"' "${DEPLOY_DIR}/Dockerfile"; then
  echo "deploy/Dockerfile must keep Go backend compilation within 1G VPS memory limits" >&2
  exit 1
fi

echo "Checking runtime image pull happens before live install..."
deploy_script="${DEPLOY_DIR}/deploy-1g.sh"
pull_line="$(awk '/docker compose --env-file \.env -f docker-compose\.1g\.yml pull caddy postgres redis/ {print NR; exit}' "${deploy_script}")"
install_line="$(awk '/Installing deployment files/ {print NR; exit}' "${deploy_script}")"
if [ -z "${pull_line}" ] || [ -z "${install_line}" ] || [ "${pull_line}" -ge "${install_line}" ]; then
  echo "deploy-1g.sh must pull runtime images in staging before installing live files" >&2
  exit 1
fi
if rg -n "docker compose -f docker-compose\\.1g\\.yml" "${DEPLOY_DIR}/deploy-1g.sh" "${DEPLOY_DIR}/check-1g.sh" "${DEPLOY_DIR}/restore-1g-config.sh" >/dev/null; then
  echo "1G remote compose commands must pass --env-file .env explicitly" >&2
  rg -n "docker compose -f docker-compose\\.1g\\.yml" "${DEPLOY_DIR}/deploy-1g.sh" "${DEPLOY_DIR}/check-1g.sh" "${DEPLOY_DIR}/restore-1g-config.sh" >&2
  exit 1
fi

echo "Checking Huana one-command deploy wrapper dry run..."
tmp_env="$(mktemp)"
rm -f "${tmp_env}"
wrapper_output="$(
  SSH_PASS=secret_ssh_password \
  CF_API_TOKEN=secret_cloudflare_token \
  DOMAIN=api.example.net \
  ENV_FILE="${tmp_env}" \
  DRY_RUN=true \
    "${DEPLOY_DIR}/huana-1g-deploy.sh" 2>&1
)"
if ! printf '%s\n' "${wrapper_output}" | grep -q 'DEPRECATED' ||
  ! printf '%s\n' "${wrapper_output}" | grep -q 'Would run: deploy/deploy.sh' ||
  printf '%s\n' "${wrapper_output}" | grep -q 'secret_ssh_password\|secret_cloudflare_token'; then
  echo "Huana deploy wrapper dry run output is incorrect or leaked secrets" >&2
  printf '%s\n' "${wrapper_output}" >&2
  exit 1
fi
if grep -q 'secret_ssh_password\|secret_cloudflare_token' "${tmp_env}"; then
  echo "Huana deploy wrapper persisted a secret into the env file" >&2
  exit 1
fi
printf 'SUDO_PASSWORD=bad_persisted_sudo_secret\n' >> "${tmp_env}"
if SSH_PASS=secret_ssh_password CF_API_TOKEN=secret_cloudflare_token ENV_FILE="${tmp_env}" DRY_RUN=true "${DEPLOY_DIR}/huana-1g-deploy.sh" >/dev/null 2>&1; then
  echo "Huana deploy wrapper accepted a persisted sudo password" >&2
  exit 1
fi
rm -f "${tmp_env}"

echo "Running cloud deployment doctor with safe sample values..."
SKIP_DNS=true \
ROLLBACK_ON_FAILURE=false \
DOMAIN=api.example.net \
TARGET_IP=45.76.12.34 \
SSH_TARGET=dhy@45.76.12.34 \
SSH_PASS=sample_password \
REMOTE_SUDO=auto \
ADMIN_EMAIL=admin@example.net \
SWAP_SIZE=1024M \
MIN_FREE_KB=1 \
MIN_DOCKER_FREE_KB=1 \
  "${DEPLOY_DIR}/doctor-1g.sh"

echo "Running 1G doctor validation tests..."
"${DEPLOY_DIR}/test-doctor-1g.sh"

echo "Running source upload deadline tests..."
"${DEPLOY_DIR}/test-upload-deadline.sh"

echo "Running simple production deploy/rollback script tests..."
"${DEPLOY_DIR}/test-simple-prod-scripts.sh"

echo "Running Cloudflare DNS mock tests..."
"${DEPLOY_DIR}/test-cloudflare-upsert-dns.sh"

echo "Running frontend probe mock tests..."
"${DEPLOY_DIR}/test-probe-frontend.sh"

echo "Running remote preflight mock tests..."
"${DEPLOY_DIR}/test-remote-1g-preflight.sh"

echo "Running remote bootstrap mock tests..."
"${DEPLOY_DIR}/test-remote-1g-bootstrap.sh"

echo "Checking remote-build source archive contents..."
tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

archive="${tmp_dir}/source.tar.gz"
git -C "${ROOT_DIR}" archive --format=tar "$(git -C "${ROOT_DIR}" write-tree)" | gzip -c > "${archive}"

tar -tzf "${archive}" | awk '
  $0 == "deploy/Dockerfile" { dockerfile = 1 }
  $0 == "deploy/Dockerfile.prebuilt" { prebuilt = 1 }
  $0 == "deploy/Dockerfile.binary" { binary = 1 }
  $0 == "frontend/package.json" { frontend = 1 }
  $0 == "frontend/pnpm-lock.yaml" { lockfile = 1 }
  $0 == "backend/go.mod" { backend = 1 }
  $0 == "frontend/vite.config.ts" { vite_ts = 1 }
  $0 == "frontend/vite.config.js" { bad_vite_js = 1 }
  $0 ~ /^\.env($|\.)/ && $0 !~ /\.example$/ { bad_env = 1 }
  $0 ~ /^deploy\/\.env($|\.)/ && $0 !~ /\.example$/ { bad_env = 1 }
  $0 == "deploy/deploy-1g.env.local" { bad_env = 1 }
  $0 ~ /^deploy\/.*report.*\.json$/ { bad_report = 1 }
  $0 ~ /^frontend\/node_modules\// { bad_node_modules = 1 }
  END {
    if (!dockerfile || !prebuilt || !binary || !frontend || !lockfile || !backend || !vite_ts || bad_vite_js || bad_env || bad_report || bad_node_modules) {
      print "source archive is missing required files or includes excluded files" > "/dev/stderr"
      exit 1
    }
  }
'

echo "1G cloud deployment test suite passed"
