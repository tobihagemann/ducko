#!/bin/bash
# Edit profile fields and optionally save.
# Opens the profile sheet first if not already open.
# Usage: ducko-edit-profile.sh [--fullname NAME] [--nickname NICK] [--email EMAIL] [--save]
set -euo pipefail

FULLNAME="__none__"
NICKNAME="__none__"
EMAIL="__none__"
SAVE="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fullname) FULLNAME="$2"; shift 2 ;;
        --nickname) NICKNAME="$2"; shift 2 ;;
        --email)    EMAIL="$2"; shift 2 ;;
        --save)     SAVE="yes"; shift ;;
        *)
            echo "Usage: ducko-edit-profile.sh [--fullname NAME] [--nickname NICK] [--email EMAIL] [--save]" >&2
            exit 1
            ;;
    esac
done

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

# Open profile sheet
"$SCRIPTS/ducko-profile.sh" > /dev/null 2>&1
sleep 0.5

RESULT=$(osascript - "$FULLNAME" "$NICKNAME" "$EMAIL" "$SAVE" << 'APPLESCRIPT'
on run argv
    set fullnameArg to item 1 of argv
    set nicknameArg to item 2 of argv
    set emailArg to item 3 of argv
    set saveArg to item 4 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find the window containing the profile edit view
            set profileWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "profile-edit-view" then
                            set profileWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if profileWin is not missing value then exit repeat
            end repeat
            if profileWin is missing value then return "ERROR: profile sheet not found"

            set allElems to entire contents of profileWin

            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "profile-fullname-field" and fullnameArg is not "__none__" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke fullnameArg
                    end if
                    if elemId is "profile-nickname-field" and nicknameArg is not "__none__" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke nicknameArg
                    end if
                    if elemId is "profile-email-field-0" and emailArg is not "__none__" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke emailArg
                    end if
                    if elemId is "profile-save-button" and saveArg is "yes" then
                        click elem
                    end if
                end try
            end repeat
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Profile updated"
else
    echo "$RESULT" >&2
    exit 1
fi
