#!/bin/bash
# Type a message in the chat input field and press Return to send.
# Usage: ducko-send.sh MESSAGE
set -euo pipefail

MESSAGE="${1:?Usage: ducko-send.sh MESSAGE}"

osascript - "$MESSAGE" << 'APPLESCRIPT'
on run argv
    set msg to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            -- Find the message text field and type
            set allElements to entire contents of window 1
            repeat with elem in allElements
                try
                    if role of elem is "AXTextField" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke msg
                    end if
                end try
            end repeat
        end tell
        delay 0.3
        keystroke return
    end tell
end run
APPLESCRIPT

echo "Sent: $MESSAGE"
