#!/bin/bash
# Destroy a room via Room Settings sheet.
# Opens Room Settings first, then clicks the Destroy Room button.
#
# Walks the sheet via findByAttr rather than `entire contents`, which collapses
# on the nested settings sheet on macOS 26.
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
on findByAttr(el, attrName, attrValue, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (value of attribute attrName of c) is attrValue then return c
                end try
                set found to my findByAttr(c, attrName, attrValue, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByAttr

on findByRoleAndName(el, roleWanted, nameWanted, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (role of c) is roleWanted and (name of c) is nameWanted then return c
                end try
                set found to my findByRoleAndName(c, roleWanted, nameWanted, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByRoleAndName

on run
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        -- Find and click the destroy button.
        set destroyBtn to missing value
        set destroyWin to missing value
        repeat with win in (windows of process "DuckoApp")
            set destroyBtn to my findByAttr(win, "AXIdentifier", "room-settings-destroy", 0, 30)
            if destroyBtn is not missing value then
                set destroyWin to win
                exit repeat
            end if
        end repeat
        if destroyBtn is missing value then return "ERROR: room-settings-destroy button not found"
        click destroyBtn
        delay 0.5

        -- Confirm the destruction in the confirmation dialog.
        set confirmBtn to missing value
        repeat with win in (windows of process "DuckoApp")
            set confirmBtn to my findByRoleAndName(win, "AXButton", "Destroy", 0, 30)
            if confirmBtn is not missing value then
                click confirmBtn
                return "ok"
            end if
        end repeat
        return "ERROR: Destroy confirmation button not found"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Destroy room initiated for $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
