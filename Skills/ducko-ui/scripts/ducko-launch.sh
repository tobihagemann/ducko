#!/bin/bash
# Build and launch DuckoApp, output the window ID.
# Usage: ducko-launch.sh
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

swift build 2>&1 | tail -1 >&2
swift run DuckoApp &>/dev/null &
APP_PID=$!

# Wait up to 15 seconds for the window to appear
for i in $(seq 1 15); do
    if WID=$("$SCRIPTS_DIR/ducko-window-id.sh" 2>/dev/null); then
        echo "$WID"
        exit 0
    fi
    sleep 1
done

echo "ERROR: DuckoApp window did not appear within 15 seconds" >&2
kill "$APP_PID" 2>/dev/null || true
exit 1
