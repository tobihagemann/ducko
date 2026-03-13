#!/bin/bash
set -euo pipefail

# Installs the pre-commit hook for Ducko.
# Run once after cloning: ./Scripts/install-hooks.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOKS_DIR="${PROJECT_ROOT}/.git/hooks"

mkdir -p "${HOOKS_DIR}"

cat > "${HOOKS_DIR}/pre-commit" << 'HOOK'
#!/bin/bash
exec ./Scripts/lint.sh --check
HOOK

chmod +x "${HOOKS_DIR}/pre-commit"

echo "Pre-commit hook installed."
