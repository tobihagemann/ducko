#!/bin/bash
# Retract a message via its context menu in the active chat window.
# Usage: ducko-retract.sh [TEXT]
#   No args:   retracts the last outgoing message
#   TEXT:       retracts the first message containing TEXT
set -euo pipefail

TEXT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript - "$TEXT" << APPLESCRIPT
on run argv
    set searchText to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "message-field" "no chat window found" "chatWin")

            -- Collect message text elements
            set allElems to entire contents of chatWin
            set targetElem to missing value
            repeat with elem in allElems
                try
                    if role of elem is "AXStaticText" then
                        set elemVal to value of elem
                        if searchText is "" then
                            set targetElem to elem
                        else if elemVal contains searchText then
                            set targetElem to elem
                            exit repeat
                        end if
                    end if
                end try
            end repeat
            if targetElem is missing value then return "ERROR: no matching message found"

            $(ducko_as_click_context_menu_item "Retract" 'targetElem' 'chatWin' "Retract menu item not found (not an outgoing message?)")
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Message retracted"
