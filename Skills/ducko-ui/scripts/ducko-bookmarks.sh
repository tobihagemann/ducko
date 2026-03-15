#!/bin/bash
# Open the Bookmarks sheet from the contact list toolbar.
# Uses accessibility identifiers for reliable targeting.
# Usage: ducko-bookmarks.sh
set -euo pipefail

RESULT=$(osascript << 'APPLESCRIPT'
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
        -- Click the Bookmarks toolbar button (try direct button first)
        set clicked to false
        set allElems to entire contents of contactWin
        repeat with elem in allElems
            try
                if value of attribute "AXIdentifier" of elem is "bookmarks-toolbar-button" then
                    click elem
                    set clicked to true
                    exit repeat
                end if
            end try
        end repeat
        -- Fall back to description matching
        if not clicked then
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and description of elem is "Bookmarks" then
                        click elem
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
        end if
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
                    if role of elem is "AXMenuItem" and name of elem is "Bookmarks" then
                        click elem
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
        end if
        if not clicked then return "ERROR: Bookmarks button not found"
        delay 1
        return "ok"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Bookmarks sheet opened"
else
    echo "$RESULT" >&2
    exit 1
fi
