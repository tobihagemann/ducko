#!/bin/bash
# Print the window ID of the first DuckoApp window, or fail.
# Usage: ducko-window-id.sh
set -euo pipefail

WID=$(peekaboo list windows --app DuckoApp --json 2>/dev/null \
    | python3 -c "import json,sys; w=json.load(sys.stdin)['data']['windows']; print(w[0]['window_id'] if w else '')" 2>/dev/null)

if [[ -z "$WID" ]]; then
    echo "ERROR: No DuckoApp window found" >&2
    exit 1
fi

echo "$WID"
