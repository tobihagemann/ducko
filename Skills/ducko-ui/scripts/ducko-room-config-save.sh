#!/bin/bash
# Save room config in the Room Settings sheet.
# Opens Room Settings first, then clicks the Save button.
# Usage: ducko-room-config-save.sh ROOM_JID
#   ROOM_JID: The JID of the room (must be visible in the Rooms section)
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-room-config-save.sh ROOM_JID" >&2
    exit 1
fi

ROOM_JID="$1"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# Open Room Settings sheet
"$SCRIPTS/ducko-room-settings.sh" "$ROOM_JID" > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoApp" to true
    delay 0.3
    tell process "DuckoApp"
        -- Find the save button by accessibility identifier
        repeat with win in windows
            set allElems to entire contents of win
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "room-config-save" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
        end repeat
        return "ERROR: room-config-save button not found"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Room config saved for $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
