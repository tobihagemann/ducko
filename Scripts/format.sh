#!/bin/bash
set -euo pipefail

# Ducko auto-format script
# Usage:
#   ./Scripts/format.sh   # Format + autocorrect all files

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

echo "Formatting all files..."
swiftformat .

echo "Linting (autocorrect)..."
swiftlint lint --fix --quiet
# Second pass from the sibling package, mirroring lint.sh: SwiftLint's SPM-aware test-target
# detection only works when invoked from the package that declares the target, so a violation in
# IntegrationTests/ is reported by `lint.sh` and would go unfixed here without this.
(cd "${PROJECT_ROOT}/IntegrationTests" && swiftlint lint --fix --quiet)

echo "Done."
