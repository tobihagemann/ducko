#!/usr/bin/env bash
# Kill running instances, package, relaunch, verify.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/version.env"

EXEC_NAME=${EXEC_NAME:-DuckoApp}
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
# Anchored to this checkout's executables so neither an installed production app, which shares EXEC_NAME, nor a
# compiler or linker writing into .build is matched.
APP_PROCESS_PATTERN="^${APP_BUNDLE}/Contents/MacOS/${EXEC_NAME}( |$)"
# `swift run` launches the build product by its path relative to the checkout.
BUILD_PROCESS_PATTERN="^(${ROOT_DIR}/|\./)?\.build/[^ ]*/${EXEC_NAME}( |$)"
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
pkill -f "${BUILD_PROCESS_PATTERN}" 2>/dev/null || true

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
# `open` does not pass the caller's environment to the app, so forward the profile explicitly. The `+` expansion
# below keeps an empty array from tripping `set -u` in bash 3.2.
OPEN_ARGS=()
if [[ -n "${DUCKO_PROFILE:-}" ]]; then
  OPEN_ARGS+=(--env "DUCKO_PROFILE=${DUCKO_PROFILE}")
fi
if ! open ${OPEN_ARGS[@]+"${OPEN_ARGS[@]}"} "${APP_BUNDLE}"; then
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
