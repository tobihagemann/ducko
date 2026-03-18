#!/bin/bash
# Right-click a message in the active chat window and select Reply.
# Usage: ducko-reply.sh [TEXT]
#   No args:   replies to the last message
#   TEXT:       replies to the first message containing TEXT
set -euo pipefail

TEXT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript - "$TEXT" << APPLESCRIPT
on run argv
    set searchText to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "message-field" "no chat window found" "chatWin")

            $(ducko_as_find_message_by_text "searchText" "chatWin")

            $(ducko_as_click_context_menu_item "Reply" 'targetElem' 'chatWin')
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Reply compose bar opened"
