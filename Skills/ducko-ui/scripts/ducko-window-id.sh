#!/bin/bash
# Print the window ID of the first Ducko window, or fail.
# Usage: ducko-window-id.sh
# Note: Peekaboo targets the bundle display name ("Ducko"), not the executable
# name ("DuckoApp"); osascript's `process "DuckoApp"` uses the executable name.
set -euo pipefail

WID=$(peekaboo list windows --app Ducko --json 2>/dev/null \
    | python3 -c "import json,sys; w=json.load(sys.stdin)['data']['windows']; print(w[0]['window_id'] if w else '')" 2>/dev/null)

if [[ -z "$WID" ]]; then
    echo "ERROR: No Ducko window found" >&2
    exit 1
fi

echo "$WID"
