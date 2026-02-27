#!/bin/bash
# Capture a screenshot of the DuckoApp window.
# Usage: ducko-screenshot.sh [FILENAME]
# Output path: /tmp/claude/FILENAME (default: ducko-screenshot.png)
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
FILENAME="${1:-ducko-screenshot.png}"
OUTPUT="/tmp/claude/$FILENAME"
mkdir -p /tmp/claude

WID=$("$SCRIPTS_DIR/ducko-window-id.sh")
peekaboo image --window-id "$WID" --path "$OUTPUT" 2>&1
echo "$OUTPUT"
