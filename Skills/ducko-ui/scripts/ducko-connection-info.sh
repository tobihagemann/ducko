#!/bin/bash
# Open the Connection Info sheet from Preferences > Accounts tab.
# Uses script composition to ensure the Accounts tab is active first.
# Usage: ducko-connection-info.sh
set -euo pipefail

# Ensure Preferences window is open on the Accounts tab
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ducko-preferences.sh" > /dev/null 2>&1 || true
"$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null 2>&1 || true

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoApp" to true
    delay 0.5

    tell process "DuckoApp"
        -- Select the first account row in the list (detail pane is empty until selected)
        repeat with win in windows
            set allElems to entire contents of win
            repeat with elem in allElems
                try
                    if role of elem is "AXRow" then
                        -- Click the first row to select the account
                        click elem
                        delay 0.3
                        exit repeat
                    end if
                end try
            end repeat
        end repeat
        delay 0.3

        -- Find the Connection Info... button in any window
        repeat with win in windows
            set allElems to entire contents of win
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and name of elem is "Connection Info..." then
                        click elem
                        delay 0.5
                        return "ok"
                    end if
                end try
            end repeat
        end repeat
        return "ERROR: Connection Info... button not found (is the account connected?)"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Connection Info sheet opened"
else
    echo "$RESULT" >&2
    exit 1
fi
