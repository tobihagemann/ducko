#!/bin/bash
set -euo pipefail

# Ducko lint & format script
# Usage:
#   ./Scripts/lint.sh              # Format + autocorrect + lint all files
#   ./Scripts/lint.sh --staged     # Format + autocorrect + lint only staged files (for pre-commit hook)
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

MODE="${1:---full}"

case "${MODE}" in
    --staged)
        STAGED_FILES=$(git diff --cached --name-only --diff-filter=d -- '*.swift' | grep -v '^Sources/CLibxml2/' | grep -v '^Sources/CDnssd/' || true)
        if [ -z "${STAGED_FILES}" ]; then
            echo "No staged Swift files to lint."
            exit 0
        fi

        echo "Formatting staged files..."
        echo "${STAGED_FILES}" | xargs swiftformat

        echo "Re-staging formatted files..."
        echo "${STAGED_FILES}" | xargs git add

        echo "Linting (autocorrect) staged files..."
        echo "${STAGED_FILES}" | xargs swiftlint lint --fix --quiet

        echo "Re-staging autocorrected files..."
        echo "${STAGED_FILES}" | xargs git add
        ;;

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
        swiftlint lint --fix --quiet
        ;;
esac

echo "Done."
