#!/usr/bin/env bash
# Kill running instances, package, relaunch, verify.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/version.env"

EXEC_NAME=${EXEC_NAME:-DuckoApp}
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${EXEC_NAME}"
DEBUG_PROCESS_PATTERN="${ROOT_DIR}/.build/debug/${EXEC_NAME}"
RELEASE_PROCESS_PATTERN="${ROOT_DIR}/.build/release/${EXEC_NAME}"
RUN_TESTS=0
CONF="debug"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --test|-t) RUN_TESTS=1 ;;
    --release) CONF="release" ;;
    --help|-h)
      log "Usage: $(basename "$0") [--test] [--release]"
      log "  Default builds debug (Ducko-Dev storage, honors DUCKO_PROFILE). --release builds"
      log "  release config, which uses production data and the Keychain."
      exit 0
      ;;
    *) fail "Unknown option: ${arg}" ;;
  esac
done

if [[ "${ARCHES:-arm64}" != "arm64" ]]; then
  fail "Ducko supports Apple Silicon only (arm64)."
fi

log "==> Killing existing ${APP_NAME} instances"
pkill -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${DEBUG_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${RELEASE_PROCESS_PATTERN}" 2>/dev/null || true
pkill -x "${EXEC_NAME}" 2>/dev/null || true

if [[ "${RUN_TESTS}" == "1" ]]; then
  log "==> swift test"
  swift test -q
fi

# Default to a debug build: it compiles the `#if DEBUG` BuildEnvironment path (Ducko-Dev storage,
# file-based credentials, honors DUCKO_PROFILE), so the dev loop never touches production data or
# re-prompts for Keychain access after each ad-hoc re-sign.

log "==> package app (${CONF})"
SIGNING_MODE=adhoc "${ROOT_DIR}/Scripts/package_app.sh" "${CONF}"

log "==> launch app"
if ! open "${APP_BUNDLE}"; then
  log "WARN: open failed; launching binary directly."
  "${APP_BUNDLE}/Contents/MacOS/${EXEC_NAME}" >/dev/null 2>&1 &
  disown
fi

for _ in {1..10}; do
  if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1; then
    log "OK: ${APP_NAME} is running."
    exit 0
  fi
  sleep 0.4
done
fail "App exited immediately. Check crash logs in Console.app (User Reports)."
