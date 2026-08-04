#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/run-with-deadline.pl"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-1g.sh"

fail() {
  echo "$*" >&2
  exit 1
}

[ -x "${HELPER}" ] || fail "Missing executable upload deadline helper: ${HELPER}"
[ -f "${DEPLOY_SCRIPT}" ] || fail "Missing 1G deploy script: ${DEPLOY_SCRIPT}"
grep -Fq 'SOURCE_UPLOAD_CHUNK_BYTES' "${DEPLOY_SCRIPT}" ||
  fail "source uploads must use a bounded chunk size on unstable links"
grep -Fq 'split -b "${SOURCE_UPLOAD_CHUNK_BYTES}"' "${DEPLOY_SCRIPT}" ||
  fail "source uploads must split the archive into resumable fixed-size parts"
grep -Fq 'run_rsync --append --timeout="${SOURCE_UPLOAD_IDLE_TIMEOUT}"' "${DEPLOY_SCRIPT}" ||
  fail "source part uploads must retain append retry support and I/O idle timeout"
grep -Fq 'Source archive uploaded and checksum verified' "${DEPLOY_SCRIPT}" ||
  fail "source uploads must verify the assembled archive before the remote build"
grep -Fq 'SOURCE_UPLOAD_RETRIES' "${DEPLOY_SCRIPT}" ||
  fail "source uploads must retain retry configuration"
grep -Fq 'run_with_deadline "${SOURCE_UPLOAD_DEADLINE}"' "${DEPLOY_SCRIPT}" ||
  fail "source uploads must apply their configured whole-process deadline"

normal_output="$("${HELPER}" 5 /bin/sh -c 'printf complete')"
[ "${normal_output}" = complete ] || fail "deadline helper changed successful command output"

tmp_dir="$(mktemp -d)"
child_pid_file="${tmp_dir}/child.pid"
cleanup() {
  if [ -f "${child_pid_file}" ]; then
    child_pid="$(cat "${child_pid_file}")"
    kill -KILL "${child_pid}" 2>/dev/null || true
  fi
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

# Exercise the actual shell functions against a local fake remote directory.
# This verifies the assembled result, not merely the presence of rsync flags.
upload_functions="${tmp_dir}/upload-functions.sh"
chunk_archive="${tmp_dir}/source.tar.gz"
chunk_remote_dir="${tmp_dir}/remote"
chunk_remote_archive="${chunk_remote_dir}/source.tar.gz"
mkdir -p "${chunk_remote_dir}"
head -c 5242880 /dev/zero > "${chunk_archive}"
sed -n '/^sha256_file() {/,/^remote_validate_caddyfile() {/p' "${DEPLOY_SCRIPT}" | sed '$d' > "${upload_functions}"
TEST_DIR="${tmp_dir}" ARCHIVE="${chunk_archive}" REMOTE_ARCHIVE="${chunk_remote_archive}" FUNCTIONS_FILE="${upload_functions}" bash -s <<'BASH'
set -euo pipefail
single_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"; }
tmp_dir="$TEST_DIR"
SOURCE_UPLOAD_CHUNK_BYTES=2097152
SOURCE_UPLOAD_RETRIES=2
SOURCE_UPLOAD_IDLE_TIMEOUT=5
SSH_TARGET=fake
run_rsync() {
  local source="${@: -2:1}"
  local destination="${@: -1}"
  local target_path="${destination#fake:}"
  mkdir -p "$(dirname "$target_path")"
  cp "$source" "$target_path"
}
run_ssh() {
  local target="$1"
  shift
  [ "$target" = fake ]
  bash -c "$1"
}
source "$FUNCTIONS_FILE"
upload_source_archive "$ARCHIVE" "$REMOTE_ARCHIVE"
[ "$(sha256_file "$ARCHIVE")" = "$(sha256_file "$REMOTE_ARCHIVE")" ]
[ ! -e "${REMOTE_ARCHIVE}.parts" ]
BASH

started="$(date +%s)"
set +e
"${HELPER}" 1 /bin/sh -c '
  trap "" TERM
  ( trap "" TERM; while :; do sleep 1; done ) &
  printf "%s\\n" "$!" > "$1"
  while :; do sleep 1; done
' sh "${child_pid_file}"
deadline_status=$?
set -e
if [ "${deadline_status}" -eq 0 ]; then
  fail "deadline helper unexpectedly accepted a stalled command"
fi
elapsed="$(( $(date +%s) - started ))"
[ "${elapsed}" -le 5 ] || fail "deadline helper exceeded bounded termination window: ${elapsed}s"

[ -s "${child_pid_file}" ] || fail "stalled child pid was not recorded"
child_pid="$(cat "${child_pid_file}")"
for _ in {1..20}; do
  if ! kill -0 "${child_pid}" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "${child_pid}" 2>/dev/null; then
  fail "deadline helper leaked stalled child process ${child_pid}"
fi

echo "upload deadline tests passed"
