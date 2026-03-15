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

# Open Room Settings sheet and switch to Members tab
"$SCRIPTS/ducko-room-settings.sh" "$ROOM_JID" > /dev/null 2>&1
"$SCRIPTS/ducko-room-settings-tab.sh" Members > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$AFF_JID" << 'APPLESCRIPT'
on run argv
    set affJID to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Fill the JID field and click Add
            set allElems to entire contents of window 1
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
