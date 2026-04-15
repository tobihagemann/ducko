#!/bin/bash
set -euo pipefail

# Ducko lint & check script (read-only, exits non-zero on violations)
# Usage:
#   ./Scripts/lint.sh   # Check format + lint + unused code

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo "error: $1 not found. Install via: brew install $1"
        exit 1
    fi
}
check_tool swiftformat
check_tool swiftlint
check_tool periphery

LINT_TMP="$TMPDIR/ducko-lint-$$"
mkdir -p "$LINT_TMP"
trap 'rm -rf "$LINT_TMP"' EXIT

set +e
FAIL=0

swiftformat --lint . >"$LINT_TMP/swiftformat.out" 2>&1 &
PID_FORMAT=$!

swiftlint lint --strict --quiet >"$LINT_TMP/swiftlint.out" 2>&1 &
PID_LINT=$!

# IntegrationTests is a sibling SwiftPM package. SwiftLint's SPM-aware
# test-target detection only works when invoked from the package that
# declares the target, so run a second pass from there with its own config.
(cd "${PROJECT_ROOT}/IntegrationTests" && swiftlint lint --strict --quiet) \
    >"$LINT_TMP/swiftlint-integration.out" 2>&1 &
PID_LINT_INT=$!

# --retain-public is needed because the sibling IntegrationTests package consumes
# DuckoCore / DuckoData / DuckoXMPP as library products; Periphery scans only the
# root package and would otherwise flag their externally-used public symbols.
periphery scan --quiet --strict --retain-public >"$LINT_TMP/periphery.out" 2>&1 &
PID_PERIPHERY=$!

wait $PID_FORMAT || { echo "--- SwiftFormat ---"; cat "$LINT_TMP/swiftformat.out"; echo "error: Run './Scripts/format.sh' to auto-fix."; FAIL=1; }
wait $PID_LINT || { echo "--- SwiftLint ---"; cat "$LINT_TMP/swiftlint.out"; FAIL=1; }
wait $PID_LINT_INT || { echo "--- SwiftLint (IntegrationTests) ---"; cat "$LINT_TMP/swiftlint-integration.out"; FAIL=1; }
wait $PID_PERIPHERY || { echo "--- Periphery ---"; cat "$LINT_TMP/periphery.out"; FAIL=1; }

set -e

if [ $FAIL -ne 0 ]; then
    exit 1
fi

echo "Done."
