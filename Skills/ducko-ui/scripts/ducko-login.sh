#!/bin/bash
# Fill JID and password on the account setup screen, then click Connect.
# Uses accessibility identifiers for reliable element targeting.
# Usage: ducko-login.sh JID PASSWORD
set -euo pipefail

JID="${1:?Usage: ducko-login.sh JID PASSWORD}"
PASSWORD="${2:?Usage: ducko-login.sh JID PASSWORD}"

osascript - "$JID" "$PASSWORD" << 'APPLESCRIPT'
on run argv
    set jid to item 1 of argv
    set pw to item 2 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 1
        tell process "DuckoApp"
            set allElems to entire contents of window 1
            repeat with elem in allElems
                try
                    set elemId to value of attribute "AXIdentifier" of elem
                    if elemId is "jid-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke jid
                    end if
                    if elemId is "password-field" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke pw
                    end if
                    if elemId is "connect-button" then
                        click elem
                    end if
                end try
            end repeat
        end tell
    end tell
end run
APPLESCRIPT

echo "Login initiated for $JID"
