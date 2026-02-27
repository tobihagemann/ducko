#!/bin/bash
# Kill the DuckoApp process.
# Usage: ducko-stop.sh
set -euo pipefail

PID=$(pgrep -x DuckoApp 2>/dev/null || true)
if [[ -n "$PID" ]]; then
    kill "$PID"
    echo "DuckoApp (PID $PID) stopped"
else
    echo "DuckoApp is not running"
fi
