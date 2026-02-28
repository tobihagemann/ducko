#!/bin/bash
# Type a message in the chat input field and press Return to send.
# Uses accessibility identifiers for reliable element targeting.
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
            set allElems to entire contents of window 1
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "message-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke msg
                        delay 0.3
                        keystroke return
                        exit repeat
                    end if
                end try
            end repeat
        end tell
    end tell
end run
APPLESCRIPT

echo "Sent: $MESSAGE"
