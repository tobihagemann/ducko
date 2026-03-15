#!/bin/bash
# Register a new account via in-band registration.
# Usage: ducko-register.sh SERVER USERNAME PASSWORD [EMAIL]
#   SERVER:   The XMPP server domain (e.g., xmpp.example.com)
#   USERNAME: Desired username (local part)
#   PASSWORD: Desired password
#   EMAIL:    Optional email address
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: ducko-register.sh SERVER USERNAME PASSWORD [EMAIL]" >&2
    exit 1
fi

SERVER="$1"
USERNAME="$2"
PASSWORD="$3"
EMAIL="${4:-__none__}"

RESULT=$(osascript - "$SERVER" "$USERNAME" "$PASSWORD" "$EMAIL" << 'APPLESCRIPT'
on run argv
    set serverArg to item 1 of argv
    set usernameArg to item 2 of argv
    set passwordArg to item 3 of argv
    set emailArg to item 4 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 1
        tell process "DuckoApp"
            set allElems to entire contents of window 1

            -- Click the Register tab in the setup mode picker
            set pickerFound to false
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "setup-mode-picker" then
                        -- The picker is a segmented control; click the Register segment
                        set segElems to entire contents of elem
                        repeat with seg in segElems
                            try
                                if name of seg is "Register" then
                                    click seg
                                    set pickerFound to true
                                    exit repeat
                                end if
                            end try
                        end repeat
                        exit repeat
                    end if
                end try
            end repeat
            if not pickerFound then return "ERROR: setup-mode-picker or Register segment not found"
            delay 0.5

            -- Re-read elements after mode switch
            set allElems to entire contents of window 1

            -- Fill in the registration fields
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "register-server-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke serverArg
                    end if
                    if elemId is "register-username-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke usernameArg
                    end if
                    if elemId is "register-password-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke passwordArg
                    end if
                    if elemId is "register-email-field" and emailArg is not "__none__" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke emailArg
                    end if
                    if elemId is "register-button" then
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
    echo "Registration initiated for $USERNAME@$SERVER"
else
    echo "$RESULT" >&2
    exit 1
fi
