#!/bin/bash
# Change MUC nickname via the participant sidebar context menu.
# Right-clicks participant rows to find the one with "Change Nickname..." (your own row),
# then fills in the new nickname in the alert dialog.
# Usage: ducko-change-nickname.sh NICKNAME
set -euo pipefail

NICKNAME="${1:?Usage: ducko-change-nickname.sh NICKNAME}"

RESULT=$(osascript - "$NICKNAME" << 'APPLESCRIPT'
on run argv
    set newNick to item 1 of argv

    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5

        tell process "DuckoApp"
            -- Find the chat window (window containing message-field)
            set chatWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "message-field" then
                            set chatWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if chatWin is not missing value then exit repeat
            end repeat
            if chatWin is missing value then return "ERROR: chat window not found"

            -- Check if participant sidebar is visible
            set sidebarElem to missing value
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "participant-sidebar" then
                        set sidebarElem to elem
                        exit repeat
                    end if
                end try
            end repeat

            -- If sidebar not found, toggle it on
            if sidebarElem is missing value then
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "toggle-participant-sidebar" then
                            click elem
                            delay 0.5
                            exit repeat
                        end if
                    end try
                end repeat
                -- Re-scan for the sidebar
                set allElems to entire contents of chatWin
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "participant-sidebar" then
                            set sidebarElem to elem
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if sidebarElem is missing value then return "ERROR: participant sidebar not found"

            -- Get sidebar contents and try right-clicking each row to find "Change Nickname..."
            set sidebarElems to entire contents of sidebarElem
            set foundMenu to false
            repeat with elem in sidebarElems
                try
                    if role of elem is "AXCell" or role of elem is "AXRow" or role of elem is "AXGroup" then
                        perform action "AXShowMenu" of elem
                        delay 0.3
                        -- Check if "Change Nickname..." appeared in the context menu
                        set menuElems to entire contents of chatWin
                        repeat with mElem in menuElems
                            try
                                if role of mElem is "AXMenuItem" and name of mElem is "Change Nickname…" then
                                    click mElem
                                    set foundMenu to true
                                    exit repeat
                                end if
                            end try
                        end repeat
                        if foundMenu then exit repeat
                        -- Dismiss the context menu if not found
                        keystroke (ASCII character 27)
                        delay 0.2
                    end if
                end try
            end repeat
            if not foundMenu then return "ERROR: Change Nickname menu item not found (are you in this room?)"

            delay 0.5

            -- Find the nickname field in the alert dialog
            set filled to false
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "change-nickname-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke newNick
                        set filled to true
                        exit repeat
                    end if
                end try
            end repeat
            if not filled then return "ERROR: change-nickname-field not found"
            delay 0.3

            -- Click the Change button
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and name of elem is "Change" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: Change button not found"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Nickname changed to $NICKNAME"
else
    echo "$RESULT" >&2
    exit 1
fi
