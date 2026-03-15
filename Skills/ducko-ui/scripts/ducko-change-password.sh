#!/bin/bash
# Change account password via Preferences > Accounts.
# Requires the Preferences window to be open on the Accounts tab.
# Usage: ducko-change-password.sh NEW_PASSWORD
#   NEW_PASSWORD: The new password to set
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-change-password.sh NEW_PASSWORD" >&2
    exit 1
fi

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
NEW_PASSWORD="$1"

# Open Preferences > Accounts
"$SCRIPTS/ducko-preferences.sh" > /dev/null 2>&1
"$SCRIPTS/ducko-preferences-tab.sh" Accounts > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$NEW_PASSWORD" << 'APPLESCRIPT'
on run argv
    set newPw to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find the Preferences window and click the first account row
            set prefsWin to missing value
            repeat with win in windows
                try
                    if name of win contains "Settings" or name of win contains "Preferences" then
                        set prefsWin to win
                        exit repeat
                    end if
                end try
            end repeat
            if prefsWin is missing value then set prefsWin to window 1

            -- Click first row to show account detail
            set allElems to entire contents of prefsWin
            repeat with elem in allElems
                try
                    if role of elem is "AXRow" then
                        click elem
                        exit repeat
                    end if
                end try
            end repeat
            delay 0.5

            -- Look for "Change Password" button and click it
            set allElems to entire contents of prefsWin
            set cpBtn to missing value
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and name of elem contains "Change Password" then
                        set cpBtn to elem
                        click elem
                        exit repeat
                    end if
                end try
            end repeat
            if cpBtn is missing value then return "ERROR: Change Password button not found"
            delay 0.5

            -- Fill in the new password and confirmation fields
            set allElems to entire contents of prefsWin
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "new-password-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke newPw
                    end if
                    if elemId is "confirm-password-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke newPw
                    end if
                end try
            end repeat

            -- Confirm by pressing Return or clicking a Save/Change button
            keystroke return
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Password change submitted"
else
    echo "$RESULT" >&2
    exit 1
fi
