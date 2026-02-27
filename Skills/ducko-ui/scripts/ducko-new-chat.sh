#!/bin/bash
# Open the New Chat sheet, fill in a JID, and click Start Chat.
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
            -- Click New Chat (try direct toolbar button, fall back to overflow menu)
            set clicked to false
            try
                click button "New Chat" of toolbar 1 of window 1
                set clicked to true
            end try
            if not clicked then
                click pop up button 1 of toolbar 1 of window 1
                delay 0.5
                click menu item "New Chat" of menu 1 of pop up button 1 of toolbar 1 of window 1
            end if
            delay 1
            -- Type JID and start chat
            keystroke jid
            delay 0.3
            click button 2 of group 1 of sheet 1 of window 1
        end tell
    end tell
end run
APPLESCRIPT

echo "Chat started with $JID"
