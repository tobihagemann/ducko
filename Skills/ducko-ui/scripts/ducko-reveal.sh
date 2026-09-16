#!/bin/bash
# Right-click a message in the active chat window and select Reveal in Finder.
# Only messages carrying a file this app saved offer the item; a link a contact sent does not.
# Usage: ducko-reveal.sh [TEXT]
#   No args:   reveals the last message's saved files
#   TEXT:      reveals the first message whose label contains TEXT (e.g. the file name)
#
# A file-only message has no static text: its name lives only in the merged
# `message-bubble-{id}` label, which SwiftUI exposes as an attributed description
# that AppleScript cannot read (it reports "button"). Peekaboo reads it, so the
# bubble is located there and then right-clicked by its identifier.
set -euo pipefail

TEXT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

# Picks a `message-bubble-*` element whose label contains the search text. Peekaboo
# does not list elements in on-screen order (buttons come before other roles), so
# bubbles are ordered by their vertical position: a search takes the topmost match,
# and no search text takes the bottom-most bubble, which is the newest message.
BUBBLE_PICKER='
import json, sys
text = sys.argv[1]
matches = []
def walk(node):
    if isinstance(node, dict):
        ident = str(node.get("identifier") or "")
        label = str(node.get("description") or node.get("label") or "")
        if ident.startswith("message-bubble") and text in label:
            y = (node.get("bounds") or {}).get("y", 0)
            matches.append((y, ident))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(sys.stdin))
if matches:
    matches.sort()
    print(matches[0][1] if text else matches[-1][1])
'

WID=$("$SCRIPT_DIR/ducko-window-id.sh")
SHOT_DIR="$(mktemp -d)"
if ! ELEMENTS=$(peekaboo see --window-id "$WID" --capture-engine classic --path "$SHOT_DIR/ducko-reveal.png" --json 2>/dev/null); then
    rm -rf "$SHOT_DIR"
    echo "ERROR: Peekaboo could not read the chat window" >&2
    exit 1
fi
rm -rf "$SHOT_DIR"
BUBBLE_ID=$(printf '%s' "$ELEMENTS" | python3 -c "$BUBBLE_PICKER" "$TEXT" 2>/dev/null || true)

if [[ -z "$BUBBLE_ID" ]]; then
    echo "ERROR: no matching message found" >&2
    exit 1
fi

RESULT=$(osascript - "$BUBBLE_ID" << APPLESCRIPT
$(ducko_as_handlers)
on run argv
    set bubbleID to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "message-field" "no chat window found" "chatWin")

            set targetElem to my findByAttr(chatWin, "AXIdentifier", bubbleID, 0, 30)
            if targetElem is missing value then return "ERROR: no matching message found"

            $(ducko_as_click_context_menu_item "Reveal in Finder" 'targetElem' 'chatWin')
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Revealed in Finder"
