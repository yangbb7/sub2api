#!/usr/bin/env sh
set -eu

BASE_URL="${BASE_URL:-${1:-}}"
CHECK_HEALTH="${CHECK_HEALTH:-true}"
ATTEMPTS="${ATTEMPTS:-1}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-20}"
CURL_RESOLVE="${CURL_RESOLVE:-}"

if [ -z "${BASE_URL}" ]; then
  echo "BASE_URL is required" >&2
  exit 1
fi

case "${CHECK_HEALTH}" in
  true|false) ;;
  *)
    echo "CHECK_HEALTH must be true or false" >&2
    exit 1
    ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

BASE_URL="${BASE_URL%/}"

fetch_url() {
  if [ -n "${CURL_RESOLVE}" ]; then
    curl -fsS --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" --resolve "${CURL_RESOLVE}" "$1"
  else
    curl -fsS --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" "$1"
  fi
}

absolute_url() {
  case "$1" in
    http://*|https://*) printf '%s\n' "$1" ;;
    /*) printf '%s%s\n' "${BASE_URL}" "$1" ;;
    *) printf '%s/%s\n' "${BASE_URL}" "$1" ;;
  esac
}

probe_once() {
  if [ "${CHECK_HEALTH}" = true ]; then
    fetch_url "${BASE_URL}/health" >/dev/null
  fi

  html="$(fetch_url "${BASE_URL}/login")"
  printf '%s\n' "${html}" | grep -q '<div id="app"' || {
    echo "login page did not include the Vue app root" >&2
    return 1
  }

  main_js="$(
    printf '%s\n' "${html}" |
      grep -Eo 'src="[^"]*/assets/[^"]+\.js"' |
      head -n 1 |
      sed 's/^src="//;s/"$//' || true
  )"
  if [ -z "${main_js}" ]; then
    echo "login page did not reference a built frontend JS asset" >&2
    return 1
  fi

  fetch_url "$(absolute_url "${main_js}")" >/dev/null
}

i=1
last_error=""
while [ "${i}" -le "${ATTEMPTS}" ]; do
  if last_error="$(probe_once 2>&1)"; then
    echo "Frontend probe passed: ${BASE_URL}/health, ${BASE_URL}/login, and built frontend assets"
    exit 0
  fi
  if [ "${i}" -lt "${ATTEMPTS}" ]; then
    sleep "${SLEEP_SECONDS}"
  fi
  i=$((i + 1))
done

echo "Frontend probe failed: ${BASE_URL}" >&2
if [ -n "${last_error}" ]; then
  printf '%s\n' "${last_error}" >&2
fi
exit 1
