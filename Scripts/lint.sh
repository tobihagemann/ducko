#!/bin/bash
set -euo pipefail

# Ducko lint & format script
# Usage:
#   ./Scripts/lint.sh              # Format + autocorrect + lint all files
#   ./Scripts/lint.sh --check      # Check-only mode for CI (exits non-zero on violations)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo "error: $1 not found. Install via: brew install $1"
        exit 1
    fi
}
check_tool swiftlint
check_tool swiftformat

case "${1:-}" in
    --check)
        echo "Checking format..."
        FORMAT_OUTPUT=$(swiftformat --lint . 2>&1) || {
            echo "${FORMAT_OUTPUT}"
            echo ""
            echo "error: SwiftFormat violations found. Run './Scripts/lint.sh' to auto-fix."
            exit 1
        }

        echo "Linting..."
        swiftlint lint --strict --quiet
        ;;

    *)
        echo "Formatting all files..."
        swiftformat .

        echo "Linting (autocorrect)..."
        swiftlint lint --fix --strict --quiet

        echo "Linting..."
        swiftlint lint --strict --quiet
        ;;
esac

echo "Done."
