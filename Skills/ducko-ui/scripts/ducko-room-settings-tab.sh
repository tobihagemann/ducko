#!/bin/bash
# Switch to a specific tab in the Room Settings sheet.
# The Room Settings sheet must already be open (use ducko-room-settings.sh first).
# Usage: ducko-room-settings-tab.sh <General|Members>
set -euo pipefail

TAB="${1:?Usage: ducko-room-settings-tab.sh <General|Members>}"

RESULT=$(osascript - "$TAB" << 'APPLESCRIPT'
on run argv
    set tabName to item 1 of argv
    set tabNames to {"General", "Members"}
    if tabName is not in tabNames then return "ERROR: unknown tab: " & tabName
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find the window containing the room settings view
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "room-settings-view" then
                            -- Click the tab (rendered as radio button by segmented picker)
                            repeat with el2 in allElems
                                try
                                    if role of el2 is "AXRadioButton" and name of el2 is tabName then
                                        click el2
                                        return "ok"
                                    end if
                                end try
                            end repeat
                            return "ERROR: tab " & tabName & " not found in room settings"
                        end if
                    end try
                end repeat
            end repeat
            return "ERROR: room settings sheet not found (open it with ducko-room-settings.sh first)"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Switched to tab: $TAB"
else
    echo "$RESULT" >&2
    exit 1
fi
