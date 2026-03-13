#!/bin/bash
# Remove the current avatar via the profile sheet.
# Opens the profile sheet if not already open, clicks "Remove Photo".
# Usage: ducko-avatar-remove.sh
set -euo pipefail

# Ensure profile sheet is open
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ducko-profile.sh" > /dev/null 2>&1 || true

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoApp" to true
    delay 0.5

    tell process "DuckoApp"
        -- Find the window with the profile sheet
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
        if profileWin is missing value then return "ERROR: Profile sheet not found"

        -- Click "Remove Photo" button
        set clicked to false
        set allElems to entire contents of profileWin
        repeat with elem in allElems
            try
                if value of attribute "AXIdentifier" of elem is "profile-remove-photo-button" then
                    click elem
                    set clicked to true
                    exit repeat
                end if
            end try
        end repeat
        if not clicked then return "ERROR: Remove Photo button not found (no avatar set?)"

        delay 2
        return "ok"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Avatar removed"
else
    echo "$RESULT" >&2
    exit 1
fi
