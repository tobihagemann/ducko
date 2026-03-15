#!/bin/bash
# Switch to a specific chat tab by JID.
# Usage: ducko-switch-tab.sh JID
#   JID: The JID of the chat tab to switch to
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-switch-tab.sh JID" >&2
    exit 1
fi

TAB_JID="$1"

RESULT=$(osascript - "$TAB_JID" << 'APPLESCRIPT'
on run argv
    set tabJID to item 1 of argv
    set targetId to "chat-tab-" & tabJID
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Search all windows for the tab
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is targetId then
                            click elem
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "ERROR: chat tab not found for " & tabJID
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Switched to tab $TAB_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
