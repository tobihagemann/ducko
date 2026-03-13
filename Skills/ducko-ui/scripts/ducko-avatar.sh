#!/bin/bash
# Upload an avatar image via the profile sheet.
# Opens the profile sheet if not already open, clicks "Change Photo",
# and navigates the file importer to the specified image.
# Usage: ducko-avatar.sh IMAGE_PATH
set -euo pipefail

IMAGE_PATH="${1:?Usage: ducko-avatar.sh IMAGE_PATH}"

# Resolve to absolute path
if [[ "$IMAGE_PATH" != /* ]]; then
    IMAGE_PATH="$(cd "$(dirname "$IMAGE_PATH")" && pwd)/$(basename "$IMAGE_PATH")"
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
    echo "ERROR: File not found: $IMAGE_PATH" >&2
    exit 1
fi

# Ensure profile sheet is open
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ducko-profile.sh" > /dev/null 2>&1 || true

RESULT=$(osascript - "$IMAGE_PATH" << 'APPLESCRIPT'
on run argv
    set imagePath to item 1 of argv

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

            -- Click "Change Photo" button
            set clicked to false
            set allElems to entire contents of profileWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "profile-change-photo-button" then
                        click elem
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
            if not clicked then return "ERROR: Change Photo button not found"

            -- Wait for the file importer (NSOpenPanel) to appear
            delay 1.5

            -- Navigate to the file using Cmd+Shift+G (Go to Folder)
            keystroke "g" using {command down, shift down}
            delay 1

            -- Type the file path and press Return
            keystroke imagePath
            delay 0.5
            keystroke return
            delay 1

            -- Press Return again to select the file
            keystroke return
            delay 2

            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Avatar uploaded"
else
    echo "$RESULT" >&2
    exit 1
fi
