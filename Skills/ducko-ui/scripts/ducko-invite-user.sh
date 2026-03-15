#!/bin/bash
# Invite a user to a room via its context menu.
# Usage: ducko-invite-user.sh ROOM_JID INVITEE_JID
#   ROOM_JID:    The JID of the room (must be visible in the Rooms section)
#   INVITEE_JID: The JID of the user to invite
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: ducko-invite-user.sh ROOM_JID INVITEE_JID" >&2
    exit 1
fi

ROOM_JID="$1"
INVITEE_JID="$2"

RESULT=$(osascript - "$ROOM_JID" "$INVITEE_JID" << 'APPLESCRIPT'
on run argv
    set roomJID to item 1 of argv
    set inviteeJID to item 2 of argv
    set targetId to "room-row-" & roomJID
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

            -- Find the room row by accessibility identifier
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
            if targetRow is missing value then return "ERROR: room row not found for " & roomJID

            -- Right-click to open context menu
            perform action "AXShowMenu" of targetRow
            delay 0.5

            -- Click "Invite User…"
            set allElems to entire contents of contactWin
            set menuFound to false
            repeat with elem in allElems
                try
                    if role of elem is "AXMenuItem" and name of elem contains "Invite User" then
                        click elem
                        set menuFound to true
                        exit repeat
                    end if
                end try
            end repeat
            if not menuFound then return "ERROR: Invite User menu item not found"
            delay 0.5

            -- Fill the JID field in the invite dialog (match by placeholder text)
            set allElems to entire contents of contactWin
            set jidField to missing value
            repeat with elem in allElems
                try
                    if role of elem is "AXTextField" then
                        set placeholder to value of attribute "AXPlaceholderValue" of elem
                        if placeholder contains "JID" then
                            set jidField to elem
                            exit repeat
                        end if
                    end if
                end try
            end repeat
            if jidField is missing value then return "ERROR: JID field not found in invite dialog"
            set focused of jidField to true
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            keystroke inviteeJID
            delay 0.2
            -- Confirm with Return
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Invited $INVITEE_JID to $ROOM_JID"
else
    echo "$RESULT" >&2
    exit 1
fi
