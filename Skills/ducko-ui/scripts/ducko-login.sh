#!/bin/bash
# Fill JID and password on the account setup screen, then click Connect.
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
            -- JID field
            click text field 1 of group 1 of window 1
            delay 0.3
            keystroke "a" using command down
            delay 0.2
            keystroke jid
            delay 0.3
            -- Password field
            keystroke tab
            delay 0.3
            keystroke "a" using command down
            delay 0.2
            keystroke pw
            delay 0.3
            -- Connect
            click button 1 of group 1 of window 1
        end tell
    end tell
end run
APPLESCRIPT

echo "Login initiated for $JID"
