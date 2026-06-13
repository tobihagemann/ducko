#!/bin/bash
# Set presence status and optional status message.
# Usage: ducko-status.sh STATUS [MESSAGE]
#   STATUS: available|away|xa|dnd|offline
#   MESSAGE: optional status message text
#
# Limitation: the status control is a borderless SwiftUI `Menu` whose opened
# menu renders as a process-level nested element. osascript can't reliably
# traverse to it (`entire contents` silently truncates on the deep SwiftUI
# tree), so this script's menu-item selection is best-effort and may report
# "status menu item ... not found". The integration suite drives this control
# via Swift AX and is authoritative — see UIPresenceTests.
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

            -- Find and click the target status menu item. The SwiftUI Menu
            -- opens as a process-level menu (a sibling of the windows), not
            -- under the button or window — so search the process's menus.
            -- The borderless Menu is awkward to drive via osascript;
            -- UIPresenceTests is the authoritative check for this path.
            set clicked to false
            repeat with m in menus
                try
                    if exists (menu item targetLabel of m) then
                        click (menu item targetLabel of m)
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
            if not clicked then return "ERROR: status menu item " & targetLabel & " not found"
            delay 0.3

            -- Set a custom status message via the pull-down's "Custom…" sheet,
            -- which opens pre-set to the presence just selected above.
            if messageArg is not "__none__" then
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

                set customClicked to false
                repeat with m in menus
                    try
                        repeat with elem in (menu items of m)
                            if (name of elem) starts with "Custom" then
                                click elem
                                set customClicked to true
                                exit repeat
                            end if
                        end repeat
                    end try
                    if customClicked then exit repeat
                end repeat
                if not customClicked then return "ERROR: Custom… menu item not found"
                delay 0.5

                set msgField to missing value
                repeat with elem in (entire contents of contactWin)
                    try
                        if value of attribute "AXIdentifier" of elem is "custom-status-message-field" then
                            set msgField to elem
                            exit repeat
                        end if
                    end try
                end repeat
                if msgField is missing value then return "ERROR: custom-status-message-field not found"
                set focused of msgField to true
                delay 0.2
                keystroke "a" using command down
                delay 0.1
                keystroke messageArg
                delay 0.2
                -- Set button carries .defaultAction.
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
