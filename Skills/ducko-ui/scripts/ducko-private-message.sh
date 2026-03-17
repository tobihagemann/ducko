#!/bin/bash
# Send a MUC private message via the participant sidebar context menu.
# Right-clicks participant rows to find the target nickname's row,
# selects "Send Private Message", then types the message in the new chat window.
# Usage: ducko-private-message.sh NICKNAME
set -euo pipefail

NICKNAME="${1:?Usage: ducko-private-message.sh NICKNAME}"

RESULT=$(osascript - "$NICKNAME" << 'APPLESCRIPT'
on run argv
    set targetNick to item 1 of argv

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

            -- Find the target participant row by nickname text
            set sidebarElems to entire contents of sidebarElem
            set foundMenu to false
            repeat with elem in sidebarElems
                try
                    if role of elem is "AXStaticText" and value of elem is targetNick then
                        -- Right-click the parent row
                        set parentElem to elem
                        try
                            set parentElem to (first UI element of sidebarElem whose value of attribute "AXIdentifier" contains targetNick)
                        on error
                            set parentElem to elem
                        end try
                        perform action "AXShowMenu" of parentElem
                        delay 0.3
                        -- Find and click "Send Private Message"
                        set menuElems to entire contents of chatWin
                        repeat with mElem in menuElems
                            try
                                if role of mElem is "AXMenuItem" and name of mElem is "Send Private Message" then
                                    click mElem
                                    set foundMenu to true
                                    exit repeat
                                end if
                            end try
                        end repeat
                        if foundMenu then exit repeat
                        keystroke (ASCII character 27)
                        delay 0.2
                    end if
                end try
            end repeat
            if not foundMenu then return "ERROR: Send Private Message menu item not found for " & targetNick

            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Opened PM window for $NICKNAME"
else
    echo "$RESULT" >&2
    exit 1
fi
