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
source "$SCRIPT_DIR/ducko-helpers.sh"
"$SCRIPT_DIR/ducko-profile.sh" > /dev/null 2>&1 || true

RESULT=$(osascript - "$IMAGE_PATH" << APPLESCRIPT
on run argv
    set imagePath to item 1 of argv

    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5

        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "profile-edit-view" "Profile sheet not found" "profileWin")
            $(ducko_as_click_element_by_id '"profile-change-photo-button"' 'profileWin' "Change Photo button not found")
            $(ducko_as_navigate_file_picker 'imagePath')
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Avatar uploaded"
