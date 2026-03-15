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

RESULT=$(osascript - "$FILE_PATH" << 'APPLESCRIPT'
on run argv
    set filePath to item 1 of argv

    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5

        tell process "DuckoApp"
            -- Find the chat window (window containing message-field)
            set chatWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "message-field" then
                            set chatWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if chatWin is not missing value then exit repeat
            end repeat
            if chatWin is missing value then return "ERROR: chat window not found"

            -- Click the attachment button
            set clicked to false
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "attachment-button" then
                        click elem
                        set clicked to true
                        exit repeat
                    end if
                end try
            end repeat
            if not clicked then return "ERROR: attachment-button not found"

            -- Wait for the file picker (NSOpenPanel) to appear
            delay 1.5

            -- Navigate to the file using Cmd+Shift+G (Go to Folder)
            keystroke "g" using {command down, shift down}
            delay 1

            -- Type the file path and press Return
            keystroke filePath
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
    echo "File attached: $FILE_PATH"
else
    echo "$RESULT" >&2
    exit 1
fi
