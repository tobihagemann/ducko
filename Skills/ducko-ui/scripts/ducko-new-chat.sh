#!/bin/bash
# Open the New Chat sheet, fill in a JID, and start the chat.
# Uses accessibility identifiers and entire contents for reliable element targeting.
# Usage: ducko-new-chat.sh JID
set -euo pipefail

JID="${1:?Usage: ducko-new-chat.sh JID}"

osascript - "$JID" << 'APPLESCRIPT'
on run argv
    set jid to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            -- Open New Chat (try direct toolbar button first)
            set clicked to false
            set allElems to entire contents of window 1
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
                set menuElems to entire contents of window 1
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
            delay 1
            -- Fill JID using identifier
            set allElems to entire contents of window 1
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "new-chat-jid-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke jid
                        exit repeat
                    end if
                end try
            end repeat
            delay 0.3
            -- Start Chat has .defaultAction keyboard shortcut
            keystroke return
        end tell
    end tell
end run
APPLESCRIPT

echo "Chat started with $JID"
