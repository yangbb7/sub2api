#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/deploy/deploy-1g.env.local}"
FORCE="${FORCE:-false}"
TARGET_REGION="${TARGET_REGION:-auto}"
DOMAIN="${DOMAIN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ACME_EMAIL="${ACME_EMAIL:-}"
UPDATE_PROXY_URL="${UPDATE_PROXY_URL:-}"
JP_SSH_TARGET="${JP_SSH_TARGET:-}"
JP_TARGET_IP="${JP_TARGET_IP:-}"
HK_SSH_TARGET="${HK_SSH_TARGET:-}"
HK_TARGET_IP="${HK_TARGET_IP:-}"

case "${FORCE}" in
  true|false) ;;
  *)
    echo "FORCE must be true or false" >&2
    exit 1
    ;;
esac

case "${TARGET_REGION}" in
  auto|jp|japan|hk|hongkong) ;;
  *)
    echo "TARGET_REGION must be auto, jp, or hk" >&2
    exit 1
    ;;
esac

if [ -e "${ENV_FILE}" ] && [ "${FORCE}" != true ]; then
  echo "Refusing to overwrite existing env file: ${ENV_FILE}" >&2
  echo "Set FORCE=true only when you intentionally want to replace it." >&2
  exit 1
fi

mkdir -p "$(dirname "${ENV_FILE}")"
umask 077

cat > "${ENV_FILE}" <<EOF
# Local 1G Huana Cloud deployment config.
# This file is gitignored and chmod 600. SSH_PASS, SUDO_PASSWORD, and
# CF_API_TOKEN are intentionally omitted. Export those secrets in the shell
# before deploy.

DEPLOY_MODE=deploy
BUILD_STRATEGY=remote
TARGET_REGION=${TARGET_REGION}

JP_SSH_TARGET=${JP_SSH_TARGET}
JP_SSH_PORT=22
JP_TARGET_IP=${JP_TARGET_IP}

HK_SSH_TARGET=${HK_SSH_TARGET}
HK_SSH_PORT=22
HK_TARGET_IP=${HK_TARGET_IP}

REMOTE_SUDO=auto

DOMAIN=${DOMAIN}
CF_ZONE_ID=${CF_ZONE_ID}
PROXIED=false
TTL=1
SKIP_DNS=false
ROLLBACK_ON_FAILURE=true

REMOTE_DIR=/opt/gateway
SWAP_SIZE=2G
MIN_FREE_KB=3145728
MIN_DOCKER_FREE_KB=4194304
DOCKER_INSTALL_METHOD=auto
PLATFORM=linux/amd64
GATEWAY_IMAGE=gateway:cloud
BUILD_NODE_OPTIONS=--max-old-space-size=1280
BUILD_GOMAXPROCS=1
PNPM_REGISTRY=https://registry.npmjs.org/

ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=

TZ=Asia/Shanghai
ACME_EMAIL=${ACME_EMAIL}
REDIS_PASSWORD=
UPDATE_PROXY_URL=${UPDATE_PROXY_URL}
EOF

chmod 600 "${ENV_FILE}"

echo "Wrote ${ENV_FILE}"
echo "Secrets were not written. Export SSH_PASS and CF_API_TOKEN before doctor/deploy."
if [ -z "${DOMAIN}" ]; then
  echo "DOMAIN is still blank; set it in ${ENV_FILE} or rerun with DOMAIN=your.host.name FORCE=true" >&2
fi
if [ -z "${JP_SSH_TARGET}${JP_TARGET_IP}${HK_SSH_TARGET}${HK_TARGET_IP}" ]; then
  echo "Target servers are blank; fill JP_* and HK_* in ${ENV_FILE} from your private ops notes." >&2
fi
