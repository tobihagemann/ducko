#!/bin/bash
# Remove a contact via its context menu.
# Usage: ducko-remove-contact.sh <JID>
#   JID: The JID of the contact to remove (must be visible in the contact list)
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-remove-contact.sh <JID>" >&2
    exit 1
fi

JID="$1"

RESULT=$(osascript - "$JID" << 'APPLESCRIPT'
on run argv
    set contactJID to item 1 of argv
    set targetId to "contact-row-" & contactJID
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find the Contacts window
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
            if contactWin is missing value then return "ERROR: Contacts window not found"
            perform action "AXRaise" of contactWin
            delay 0.3

            -- Find the contact row by accessibility identifier
            set targetRow to missing value
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is targetId then
                        set targetRow to elem
                        exit repeat
                    end if
                end try
            end repeat
            if targetRow is missing value then return "ERROR: contact row not found for " & contactJID

            -- Right-click to open context menu
            perform action "AXShowMenu" of targetRow
            delay 0.5

            -- Click "Remove Contact"
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    if role of elem is "AXMenuItem" and name of elem is "Remove Contact" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: Remove Contact menu item not found"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Removed contact $JID"
else
    echo "$RESULT" >&2
    exit 1
fi
