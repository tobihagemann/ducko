#!/bin/bash
# Kill all DuckoApp processes.
# Usage: ducko-stop.sh
set -euo pipefail

# Match both "DuckoApp" (direct launch) and the full .build path (swift run)
PIDS=$(pgrep -f DuckoApp 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    kill $PIDS
    echo "DuckoApp stopped (PIDs: $(echo $PIDS | tr '\n' ' '))"
else
    echo "DuckoApp is not running"
fi
