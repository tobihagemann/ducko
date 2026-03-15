#!/bin/bash
# Set presence status and optional status message.
# Usage: ducko-status.sh STATUS [MESSAGE]
#   STATUS: available|away|xa|dnd|offline
#   MESSAGE: optional status message text
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-status.sh STATUS [MESSAGE]" >&2
    exit 1
fi

STATUS="$1"
MESSAGE="${2:-__none__}"

RESULT=$(osascript - "$STATUS" "$MESSAGE" << 'APPLESCRIPT'
on run argv
    set statusArg to item 1 of argv
    set messageArg to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find the Contacts window
            set contactWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "contact-list" then
                            set contactWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if contactWin is not missing value then exit repeat
            end repeat
            if contactWin is missing value then return "ERROR: Contacts window not found"
            perform action "AXRaise" of contactWin
            delay 0.3

            -- Map status arg to display name
            set targetLabel to ""
            if statusArg is "available" then
                set targetLabel to "Available"
            else if statusArg is "away" then
                set targetLabel to "Away"
            else if statusArg is "xa" then
                set targetLabel to "Extended Away"
            else if statusArg is "dnd" then
                set targetLabel to "Do Not Disturb"
            else if statusArg is "offline" then
                set targetLabel to "Offline"
            else
                return "ERROR: unknown status: " & statusArg
            end if

            -- Find and click the status picker menu
            set pickerBtn to missing value
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "status-picker" then
                        set pickerBtn to elem
                        exit repeat
                    end if
                end try
            end repeat
            if pickerBtn is missing value then return "ERROR: status-picker not found"
            click pickerBtn
            delay 0.3

            -- Find and click the target status menu item
            -- Strategy 1: search within the picker's own menu
            set clicked to false
            try
                set menuElems to entire contents of menu 1 of pickerBtn
                repeat with elem in menuElems
                    try
                        if role of elem is "AXMenuItem" and name of elem is targetLabel then
                            click elem
                            set clicked to true
                            exit repeat
                        end if
                    end try
                end repeat
            end try
            -- Strategy 2: fallback to window contents
            if not clicked then
                set allElems to entire contents of contactWin
                repeat with elem in allElems
                    try
                        if role of elem is "AXMenuItem" and name of elem is targetLabel then
                            click elem
                            set clicked to true
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if not clicked then return "ERROR: status menu item " & targetLabel & " not found"
            delay 0.3

            -- Optionally set the status message
            if messageArg is not "__none__" then
                set msgField to missing value
                set allElems to entire contents of contactWin
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "status-message-field" then
                            set msgField to elem
                            exit repeat
                        end if
                    end try
                end repeat
                if msgField is missing value then return "ERROR: status-message-field not found"
                set focused of msgField to true
                delay 0.2
                keystroke "a" using command down
                delay 0.1
                keystroke messageArg
                keystroke return
                delay 0.3
            end if

            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    if [[ "$MESSAGE" != "__none__" ]]; then
        echo "Status set to ${STATUS} with message"
    else
        echo "Status set to ${STATUS}"
    fi
else
    echo "$RESULT" >&2
    exit 1
fi
