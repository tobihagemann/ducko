#!/bin/bash
# Destroy a room via Room Settings sheet.
# Opens Room Settings first, then clicks the Destroy Room button.
# Usage: ducko-destroy-room.sh ROOM_JID
#   ROOM_JID: The JID of the room to destroy (must be visible in the Rooms section)
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-destroy-room.sh ROOM_JID" >&2
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
        -- Find and click the destroy button by accessibility identifier
        set destroyBtn to missing value
        repeat with win in windows
            set allElems to entire contents of win
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "room-settings-destroy" then
                        set destroyBtn to elem
                        click elem
                        exit repeat
                    end if
                end try
            end repeat
            if destroyBtn is not missing value then exit repeat
        end repeat
        if destroyBtn is missing value then return "ERROR: room-settings-destroy button not found"
        delay 0.5

        -- Confirm the destruction in the confirmation dialog
        repeat with win in windows
            set allElems to entire contents of win
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and name of elem is "Destroy" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
        end repeat
        return "ERROR: Destroy confirmation button not found"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Destroy room initiated for $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
