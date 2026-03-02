#!/bin/bash
# Toggle the search bar in the active chat window via Cmd+F.
# With a QUERY argument, types and submits the search.
# Usage: ducko-search.sh [QUERY]
#   No args:   toggles search bar open/closed
#   QUERY:     opens search bar, types QUERY, and submits
set -euo pipefail

QUERY="${1:-}"

RESULT=$(osascript - "$QUERY" << 'APPLESCRIPT'
on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            if query is "" then
                -- Toggle search bar open/closed
                keystroke "f" using command down
                delay 0.3
                return "toggled"
            end if

            -- Check if search bar is already open by looking for its identifier
            set searchField to missing value
            set chatWin to window 1
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "message-search-bar" then
                        -- Found the search bar container; find its text field
                        set searchField to elem
                        exit repeat
                    end if
                end try
            end repeat

            -- Open search bar if not already open
            if searchField is missing value then
                keystroke "f" using command down
                delay 0.5
            else
                -- Search bar already open — ensure focus is on the search field
                set focused of searchField to true
                delay 0.2
            end if

            -- Select all existing text in search field, then type query
            keystroke "a" using command down
            delay 0.1
            keystroke query
            delay 0.3
            keystroke return
            return "searched"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    toggled)  echo "Search bar toggled" ;;
    searched) echo "Searched: $QUERY" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
