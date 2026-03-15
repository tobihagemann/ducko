#!/bin/bash
# Remove a bookmark from the Bookmarks sheet.
# Opens the Bookmarks sheet first (via script composition), finds the bookmark row
# by its AXIdentifier, then clicks the corresponding remove button.
# Usage: ducko-remove-bookmark.sh ROOM_JID
set -euo pipefail

ROOM_JID="${1:?Usage: ducko-remove-bookmark.sh ROOM_JID}"

# Ensure Bookmarks sheet is open
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ducko-bookmarks.sh" > /dev/null 2>&1 || true

RESULT=$(osascript - "$ROOM_JID" << 'APPLESCRIPT'
on run argv
    set roomJID to item 1 of argv
    set targetRowId to "bookmark-row-" & roomJID
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
            -- Find the bookmark row, then click the next remove button
            set foundRow to false
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is targetRowId then
                        set foundRow to true
                    else if foundRow and elemId is "remove-bookmark-button" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            if not foundRow then return "ERROR: bookmark not found for " & roomJID
            return "ERROR: remove button not found"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Bookmark removed for $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
