#!/bin/bash
# Capture a screenshot of the DuckoApp window.
# Usage: ducko-screenshot.sh [FILENAME]
# Output path: /private/tmp/claude/FILENAME (default: ducko-screenshot.png)
# If FILENAME is an absolute path, it is used as-is.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FILENAME="${1:-ducko-screenshot.png}"

if [[ "$FILENAME" = /* ]]; then
    OUTPUT="$FILENAME"
else
    OUTPUT="/private/tmp/claude/$FILENAME"
fi
mkdir -p "$(dirname "$OUTPUT")"

WID=$("$SCRIPTS_DIR/ducko-window-id.sh")
peekaboo image --window-id "$WID" --path "$OUTPUT" 2>&1
echo "$OUTPUT"
