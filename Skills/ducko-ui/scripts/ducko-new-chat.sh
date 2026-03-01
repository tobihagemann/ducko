#!/bin/bash
# Open the New Chat sheet from the contact list, fill in a JID, and start the chat.
# The chat opens in a separate window. Uses accessibility identifiers for reliable targeting.
# Usage: ducko-new-chat.sh JID
set -euo pipefail

JID="${1:?Usage: ducko-new-chat.sh JID}"

RESULT=$(osascript - "$JID" << 'APPLESCRIPT'
on run argv
    set jid to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            -- Find the Contacts window (first window with contact list)
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
            -- Fall back to window 1 if contact list not found
            if contactWin is missing value then set contactWin to window 1
            -- Open New Chat (try toolbar button first)
            set clicked to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and description of elem is "New Chat" then
                        click elem
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
            -- Fall back to overflow menu if button not found
            if not clicked then
                repeat with elem in allElems
                    try
                        if role of elem is "AXPopUpButton" then
                            click elem
                            delay 0.5
                            exit repeat
                        end if
                    end try
                end repeat
                set menuElems to entire contents of contactWin
                repeat with elem in menuElems
                    try
                        if role of elem is "AXMenuItem" and name of elem is "New Chat" then
                            click elem
                            set clicked to true
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if not clicked then return "ERROR: New Chat button not found"
            delay 1
            -- Fill JID using identifier
            set filled to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "new-chat-jid-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke jid
                        set filled to true
                        exit repeat
                    end if
                end try
            end repeat
            if not filled then return "ERROR: new-chat-jid-field not found"
            delay 0.3
            -- Start Chat has .defaultAction keyboard shortcut
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Chat started with $JID"
else
    echo "$RESULT" >&2
    exit 1
fi
