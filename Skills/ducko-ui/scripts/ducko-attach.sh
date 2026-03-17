#!/bin/bash
# Attach a file via the attachment button in the active chat window.
# Opens the system file picker and navigates to the specified file.
# Usage: ducko-attach.sh FILE_PATH
set -euo pipefail

FILE_PATH="${1:?Usage: ducko-attach.sh FILE_PATH}"

# Resolve to absolute path
if [[ "$FILE_PATH" != /* ]]; then
    FILE_PATH="$(cd "$(dirname "$FILE_PATH")" && pwd)/$(basename "$FILE_PATH")"
fi

if [[ ! -f "$FILE_PATH" ]]; then
    echo "ERROR: File not found: $FILE_PATH" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript - "$FILE_PATH" << APPLESCRIPT
on run argv
    set filePath to item 1 of argv

    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5

        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "message-field" "chat window not found" "chatWin")
            $(ducko_as_click_element_by_id '"attachment-button"' 'chatWin' "attachment-button not found")
            $(ducko_as_navigate_file_picker 'filePath')
            return "ok"
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "File attached: $FILE_PATH"
