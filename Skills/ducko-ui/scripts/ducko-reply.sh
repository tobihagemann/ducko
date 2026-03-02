#!/bin/bash
# Right-click a message in the active chat window and select Reply.
# Usage: ducko-reply.sh [TEXT]
#   No args:   replies to the last message
#   TEXT:       replies to the first message containing TEXT
set -euo pipefail

TEXT="${1:-}"

RESULT=$(osascript - "$TEXT" << 'APPLESCRIPT'
on run argv
    set searchText to item 1 of argv
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
            if chatWin is missing value then return "ERROR: no chat window found"

            -- Collect message text elements
            set allElems to entire contents of chatWin
            set targetElem to missing value
            repeat with elem in allElems
                try
                    if role of elem is "AXStaticText" then
                        set elemVal to value of elem
                        if searchText is "" then
                            -- Track last text element as candidate
                            set targetElem to elem
                        else if elemVal contains searchText then
                            set targetElem to elem
                            exit repeat
                        end if
                    end if
                end try
            end repeat
            if targetElem is missing value then return "ERROR: no matching message found"

            -- Right-click to open context menu
            perform action "AXShowMenu" of targetElem
            delay 0.5

            -- Click Reply
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if role of elem is "AXMenuItem" and name of elem is "Reply" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: Reply menu item not found"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Reply compose bar opened"
else
    echo "$RESULT" >&2
    exit 1
fi
