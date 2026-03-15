#!/bin/bash
# Add a JID to a room's affiliation list via Room Settings > Members tab.
# Opens Room Settings first, switches to Members tab, fills JID, and clicks Add.
# Usage: ducko-add-affiliation.sh ROOM_JID JID
#   ROOM_JID: The room JID (must be visible in the Rooms section)
#   JID:      The JID to add to the affiliation list
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: ducko-add-affiliation.sh ROOM_JID JID" >&2
    exit 1
fi

ROOM_JID="$1"
AFF_JID="$2"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# Open Room Settings sheet
"$SCRIPTS/ducko-room-settings.sh" "$ROOM_JID" > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$AFF_JID" << 'APPLESCRIPT'
on run argv
    set affJID to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find the window with room settings
            set settingsWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "room-settings-view" then
                            set settingsWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if settingsWin is not missing value then exit repeat
            end repeat
            if settingsWin is missing value then return "ERROR: room settings not found"

            -- Switch to Members tab
            set allElems to entire contents of settingsWin
            repeat with elem in allElems
                try
                    if role of elem is "AXRadioButton" and name of elem is "Members" then
                        click elem
                        exit repeat
                    end if
                end try
            end repeat
            delay 0.5

            -- Fill the JID field and click Add
            set allElems to entire contents of settingsWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "affiliation-jid-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke affJID
                    end if
                    if elemId is "affiliation-add-button" then
                        click elem
                    end if
                end try
            end repeat
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Added $AFF_JID to affiliation list of $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
