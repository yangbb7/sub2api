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
grep -Fq 'run_rsync --partial --timeout="${SOURCE_UPLOAD_IDLE_TIMEOUT}"' "${DEPLOY_SCRIPT}" ||
  fail "source uploads must retain rsync partial-transfer support and I/O idle timeout"
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
