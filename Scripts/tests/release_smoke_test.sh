#!/usr/bin/env bash
set -euo pipefail

# Script-level smoke test for Scripts/release.sh. It neutralizes the expensive and
# macOS-only parts of the pipeline (the swift build inside package_app.sh, the
# signing/notarizing binaries) by PATH-shimming the bare-name tools and injecting stub
# sibling-scripts via release.sh's PACKAGE_APP_SCRIPT / CREATE_DMG_SCRIPT / DITTO_BIN
# seams, then runs the real release.sh and asserts on its observable control flow. Pure
# bash; runs on Linux where the macOS tools are absent (the stubs supply them).

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/version.env"
STUBS="$(cd "$(dirname "$0")/stubs" && pwd)"

# Distinct, clearly-fake version per fabricating case so the set of repo-root artifacts the
# run produces is concrete and the cleanup trap can target it exactly. Each version is named
# once here and referenced by both its case and TRACKED_VERSIONS, so the cleanup/guard set
# and the cases can never drift apart.
VER_DEFAULT=9.9.9
VER_OVERRIDE=9.9.7
VER_SCRATCH=9.9.6
VER_FAIL=9.9.5
VER_GIT_DESCRIBE=1.2.3
VER_NO_TAG=0.0.0
TRACKED_VERSIONS=(
  "$VER_DEFAULT" "$VER_OVERRIDE" "$VER_SCRATCH" "$VER_FAIL"
  "$VER_GIT_DESCRIBE" "$VER_NO_TAG"
)

# ---------------------------------------------------------------------------------------
# Cleanup + pre-existence guard
# ---------------------------------------------------------------------------------------

HARNESS_TMP=$(mktemp -d "${TMPDIR:-/tmp}/release-smoke-harness.XXXXXX")
GUARD_PASSED=0

cleanup() {
  rm -rf "$HARNESS_TMP"
  # Artifact removal is gated on the pre-existence guard having passed, so a guard-triggered
  # abort never deletes an operator's real dev-build bundle/archive at these same paths.
  if [[ "$GUARD_PASSED" -eq 1 ]]; then
    rm -rf "$ROOT/${APP_NAME}.app"
    local ver
    for ver in "${TRACKED_VERSIONS[@]}"; do
      rm -f "$ROOT/${APP_NAME}-${ver}.zip" "$ROOT/${APP_NAME}-${ver}.dmg"
    done
  fi
}
trap cleanup EXIT

preexistence_guard() {
  local conflicts=() ver f
  if [[ -e "$ROOT/${APP_NAME}.app" ]]; then conflicts+=("$ROOT/${APP_NAME}.app"); fi
  for ver in "${TRACKED_VERSIONS[@]}"; do
    for f in "$ROOT/${APP_NAME}-${ver}.zip" "$ROOT/${APP_NAME}-${ver}.dmg"; do
      if [[ -e "$f" ]]; then conflicts+=("$f"); fi
    done
  done
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    echo "ERROR: refusing to run; these repo-root paths already exist and would be clobbered:" >&2
    printf '  %s\n' "${conflicts[@]}" >&2
    echo "Remove or move them, then re-run from a clean working tree." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------------------

PASS=0
FAIL=0

fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  PASS=$((PASS + 1))
}

assert_exists() {
  if [[ -e "$1" ]]; then pass; else fail "expected to exist: $1"; fi
}

assert_absent() {
  if [[ ! -e "$1" ]]; then pass; else fail "expected absent: $1"; fi
}

assert_logged() {
  if grep -qF -- "$1" "$RELEASE_SMOKE_LOG"; then pass; else fail "expected in log: $1"; fi
}

assert_not_logged() {
  if grep -qF -- "$1" "$RELEASE_SMOKE_LOG"; then fail "did not expect in log: $1"; else pass; fi
}

assert_status() {
  if [[ "$1" == "$2" ]]; then pass; else fail "expected exit status $1, got $2"; fi
}

assert_stderr() {
  if grep -qF -- "$1" "$LAST_STDERR"; then pass; else fail "expected on stderr: $1 (got: $(cat "$LAST_STDERR"))"; fi
}

# release.sh's mktemp -d scratch dir (which holds the decrypted .p8) must be gone from the
# per-case TMPDIR after the run, whether it succeeded or aborted mid-pipeline.
assert_no_scratch_leftover() {
  local label="$1"
  shopt -s nullglob
  local leftover=("$LAST_TMPDIR"/ducko-release-*)
  shopt -u nullglob
  if [[ ${#leftover[@]} -eq 0 ]]; then pass; else fail "$label: scratch dir not cleaned: ${leftover[*]}"; fi
}

# slice_log START [END] — print the log lines strictly between the START marker and the
# next END marker. With no END, slice to end-of-log (the terminal phase window has no
# trailing marker, so its right edge is EOF).
slice_log() {
  local start="$1" end="${2:-}"
  if [[ -n "$end" ]]; then
    awk -v s="$start" -v e="$end" '
      index($0, s) { inwin = 1; next }
      index($0, e) { inwin = 0 }
      inwin { print }
    ' "$RELEASE_SMOKE_LOG"
  else
    awk -v s="$start" '
      index($0, s) { inwin = 1; next }
      inwin { print }
    ' "$RELEASE_SMOKE_LOG"
  fi
}

# assert_subsequence LABEL SLICE PATTERN... — verify the patterns appear in this relative
# order within SLICE (each at a line strictly after the previous match). Ordering is
# asserted within a phase window, never across the whole log by first-match, because both
# `notarytool submit` and `stapler staple` recur in every phase.
assert_subsequence() {
  local label="$1" slice="$2"
  shift 2
  local prev=0 ok=1 missing="" pat idx
  for pat in "$@"; do
    idx=$(printf '%s\n' "$slice" | grep -nF -- "$pat" | awk -F: -v after="$prev" '$1 > after { print $1; exit }' || true)
    if [[ -z "$idx" ]]; then
      ok=0
      missing="$pat (no match after line $prev)"
      break
    fi
    prev="$idx"
  done
  if [[ "$ok" -eq 1 ]]; then pass; else fail "$label: subsequence broken at $missing"; fi
}

# ---------------------------------------------------------------------------------------
# Release invocation
# ---------------------------------------------------------------------------------------

# Baseline valid environment for a passing release: dummy signing identity + ASC creds,
# and MARKETING_VERSION / SMOKE_GIT_DESCRIBE explicitly unset so no value leaks from a
# prior case into a later one. Each case calls this first, then mutates only what it tests.
reset_env() {
  export APP_IDENTITY="Developer ID Application: Smoke Test (TEST123456)"
  export APP_STORE_CONNECT_API_KEY_P8='-----BEGIN PRIVATE KEY-----\nSMOKE\n-----END PRIVATE KEY-----'
  export APP_STORE_CONNECT_KEY_ID="SMOKEKEYID"
  export APP_STORE_CONNECT_ISSUER_ID="00000000-0000-0000-0000-000000000000"
  unset ARCHES
  unset MARKETING_VERSION
  unset SMOKE_GIT_DESCRIBE
  unset SMOKE_PACKAGE_APP_EXIT
}

# run_release ARGS... — run the real release.sh with the stub-redirect environment, a fresh
# per-case log and TMPDIR (so scratch-dir cleanup is observable), capturing its exit status
# without tripping this harness's own `set -e`.
run_release() {
  RELEASE_SMOKE_LOG=$(mktemp "$HARNESS_TMP/log.XXXXXX")
  LAST_STDERR=$(mktemp "$HARNESS_TMP/stderr.XXXXXX")
  LAST_TMPDIR=$(mktemp -d "$HARNESS_TMP/tmpdir.XXXXXX")
  local rc
  if env \
    PATH="$STUBS:$PATH" \
    TMPDIR="$LAST_TMPDIR" \
    RELEASE_SMOKE_LOG="$RELEASE_SMOKE_LOG" \
    PACKAGE_APP_SCRIPT="$STUBS/package_app.sh" \
    CREATE_DMG_SCRIPT="$STUBS/create_dmg.sh" \
    DITTO_BIN="$STUBS/ditto" \
    REPO_ROOT="$ROOT" \
    APP_NAME="$APP_NAME" \
    "$ROOT/Scripts/release.sh" "$@" >/dev/null 2>"$LAST_STDERR"; then
    rc=0
  else
    rc=$?
  fi
  LAST_RC=$rc
}

# ---------------------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------------------

case_default_release() {
  echo "== default release path =="
  reset_env
  export MARKETING_VERSION="$VER_DEFAULT"
  run_release
  assert_status 0 "$LAST_RC"

  assert_logged "package_app release"
  assert_exists "$ROOT/${APP_NAME}-${VER_DEFAULT}.zip"
  assert_exists "$ROOT/${APP_NAME}-${VER_DEFAULT}.dmg"

  # Phase order across the whole log.
  assert_subsequence "phase order" "$(cat "$RELEASE_SMOKE_LOG")" \
    "--- build:app ---" "--- dmg:app ---"

  # Command order within each phase window. The distributable-zip name (e.g. Ducko-9.9.9.zip)
  # anchors the post-staple `ditto "$ROOT/$ZIP_NAME"`; the notarize zip is named
  # DuckoNotarize.zip, so this token matches only the distributable ditto and proves
  # the shipped archive is built *after* stapling (a reorder shipping an unstapled app would fail).
  assert_subsequence "build:app order" "$(slice_log '--- build:app ---' '--- dmg:app ---')" \
    "notarytool submit" "stapler staple" "${APP_NAME}-${VER_DEFAULT}.zip" "spctl" "stapler validate"
  # Terminal window: dmg:app has no trailing marker, so slice to EOF.
  assert_subsequence "dmg:app order" "$(slice_log '--- dmg:app ---')" \
    "codesign" "notarytool submit" "stapler staple"
}

case_unsupported_architecture() {
  echo "== unsupported release architecture =="
  reset_env
  export ARCHES="arm64 x86_64"
  run_release
  assert_status 1 "$LAST_RC"
  assert_stderr "Apple Silicon only"
  assert_not_logged "package_app"
}

case_missing_app_identity() {
  echo "== missing APP_IDENTITY =="
  reset_env
  unset APP_IDENTITY
  run_release
  assert_status 1 "$LAST_RC"
  assert_stderr "APP_IDENTITY"
  assert_not_logged "package_app"
}

case_missing_asc_var() {
  echo "== missing APP_STORE_CONNECT_* var =="
  reset_env
  unset APP_STORE_CONNECT_KEY_ID
  run_release
  assert_status 1 "$LAST_RC"
  assert_stderr "APP_STORE_CONNECT"
  assert_not_logged "package_app"
}

case_version_override_wins() {
  echo "== version resolution: override wins =="
  reset_env
  export MARKETING_VERSION="$VER_OVERRIDE"
  export SMOKE_GIT_DESCRIBE="$VER_GIT_DESCRIBE"
  run_release
  assert_status 0 "$LAST_RC"
  # With MARKETING_VERSION set, the `${MARKETING_VERSION:-...}` default short-circuits and
  # never calls git describe; this is a black-box name check that the override value reached
  # the name and the stub's describe value did not.
  assert_exists "$ROOT/${APP_NAME}-${VER_OVERRIDE}.zip"
  assert_absent "$ROOT/${APP_NAME}-${VER_GIT_DESCRIBE}.zip"
  assert_absent "$ROOT/${APP_NAME}-${VER_GIT_DESCRIBE}.dmg"
}

case_version_git_describe() {
  echo "== version resolution: git-describe branch =="
  reset_env
  export SMOKE_GIT_DESCRIBE="$VER_GIT_DESCRIBE"
  # MARKETING_VERSION stays unset (reset_env) so resolution reaches the git describe branch.
  run_release
  assert_status 0 "$LAST_RC"
  assert_exists "$ROOT/${APP_NAME}-${VER_GIT_DESCRIBE}.zip"
  assert_exists "$ROOT/${APP_NAME}-${VER_GIT_DESCRIBE}.dmg"
}

case_version_no_tag_fallback() {
  echo "== version resolution: no-tag 0.0.0 fallback =="
  reset_env
  # MARKETING_VERSION and SMOKE_GIT_DESCRIBE are unset, so the git stub exits non-zero
  # and release.sh falls through to its `|| echo "0.0.0"` default (the fresh-checkout path).
  run_release
  assert_status 0 "$LAST_RC"
  assert_exists "$ROOT/${APP_NAME}-${VER_NO_TAG}.zip"
  assert_exists "$ROOT/${APP_NAME}-${VER_NO_TAG}.dmg"
}

case_scratch_dir_cleanup() {
  echo "== scratch-dir cleanup (success path) =="
  reset_env
  export MARKETING_VERSION="$VER_SCRATCH"
  run_release
  assert_status 0 "$LAST_RC"
  assert_no_scratch_leftover "success path"
}

case_scratch_dir_cleanup_on_failure() {
  echo "== scratch-dir cleanup (mid-pipeline failure) =="
  reset_env
  export MARKETING_VERSION="$VER_FAIL"
  # Force package_app to fail; the scratch dir (which holds the decrypted .p8 signing key)
  # is created before the build, so the EXIT-trap rm -rf must still fire on abort.
  export SMOKE_PACKAGE_APP_EXIT=1
  run_release
  assert_status 1 "$LAST_RC"
  assert_no_scratch_leftover "mid-pipeline failure"
}

# ---------------------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------------------

preexistence_guard
GUARD_PASSED=1

case_default_release
case_unsupported_architecture
case_missing_app_identity
case_missing_asc_var
case_version_override_wins
case_version_git_describe
case_version_no_tag_fallback
case_scratch_dir_cleanup
case_scratch_dir_cleanup_on_failure

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Release smoke test FAILED." >&2
  exit 1
fi
echo "Release smoke test passed."
