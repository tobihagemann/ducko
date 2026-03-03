#!/bin/bash
# Raise the Contacts window to the front.
# Useful when a chat window is covering the contact list.
# Usage: ducko-focus-contacts.sh
set -euo pipefail

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoApp" to true
    delay 0.3
    tell process "DuckoApp"
        repeat with win in windows
            if name of win is "Contacts" then
                perform action "AXRaise" of win
                return "ok"
            end if
        end repeat
    end tell
end tell
return "ERROR: Contacts window not found"
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Contacts window raised"
else
    echo "$RESULT" >&2
    exit 1
fi
