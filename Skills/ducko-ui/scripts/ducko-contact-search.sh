#!/bin/bash
# Reveal the contact-list search field (⌘F) and optionally type a query to
# filter the roster. The field is hidden until revealed.
# Usage: ducko-contact-search.sh [QUERY]
#   No args:  toggles the search field open/closed
#   QUERY:    reveals the field and types QUERY to filter the roster
set -euo pipefail

QUERY="${1:-}"

RESULT=$(osascript - "$QUERY" << 'APPLESCRIPT'
on run argv
    set query to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            -- Find and raise the Contacts window
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
            if contactWin is missing value then set contactWin to window 1
            perform action "AXRaise" of contactWin
            delay 0.2

            -- Is the search field already visible?
            set searchField to missing value
            repeat with elem in (entire contents of contactWin)
                try
                    if value of attribute "AXIdentifier" of elem is "contact-search-field" then
                        set searchField to elem
                        exit repeat
                    end if
                end try
            end repeat

            if query is "" then
                -- Toggle: ⌘F reveals or hides the field.
                keystroke "f" using command down
                delay 0.3
                return "toggled"
            end if

            -- Reveal the field if it isn't already shown.
            if searchField is missing value then
                keystroke "f" using command down
                delay 0.5
                repeat with elem in (entire contents of contactWin)
                    try
                        if value of attribute "AXIdentifier" of elem is "contact-search-field" then
                            set searchField to elem
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if searchField is missing value then return "ERROR: contact-search-field not found"

            set focused of searchField to true
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            keystroke query
            delay 0.3
            return "searched"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    toggled)  echo "Contact search toggled" ;;
    searched) echo "Filtered contacts: $QUERY" ;;
    *)        echo "$RESULT" >&2; exit 1 ;;
esac
