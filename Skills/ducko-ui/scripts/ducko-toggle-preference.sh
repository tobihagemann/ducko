#!/bin/bash
# Toggle a preference checkbox by its accessibility identifier.
# Usage: ducko-toggle-preference.sh IDENTIFIER
#   IDENTIFIER: e.g., chatStatesToggle, displayedMarkersToggle, requireTLSToggle,
#               encryptByDefaultToggle, tofuToggle
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-toggle-preference.sh IDENTIFIER" >&2
    exit 1
fi

TOGGLE_ID="$1"

RESULT=$(osascript - "$TOGGLE_ID" << 'APPLESCRIPT'
on run argv
    set toggleId to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Search all windows for the toggle
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is toggleId then
                            click elem
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "ERROR: toggle not found: " & toggleId
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Toggled $TOGGLE_ID"
else
    echo "$RESULT" >&2
    exit 1
fi
