#!/bin/bash
# Remove a contact via its context menu.
# Usage: ducko-remove-contact.sh <JID>
#   JID: The JID of the contact to remove (must be visible in the contact list)
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: ducko-remove-contact.sh <JID>" >&2
    exit 1
fi

JID="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ducko-helpers.sh"

RESULT=$(osascript - "$JID" << APPLESCRIPT
on run argv
    set contactJID to item 1 of argv
    set targetId to "contact-row-" & contactJID
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            $(ducko_as_find_window_by_id "contact-list" "Contacts window not found" "contactWin")
            perform action "AXRaise" of contactWin
            delay 0.3
            $(ducko_as_find_element_by_id 'targetId' 'contactWin' 'contact row not found for " & contactJID & "' 'targetRow')
            $(ducko_as_click_context_menu_item "Remove Contact" 'targetRow' 'contactWin')
        end tell
    end tell
end run
APPLESCRIPT
)

ducko_check_result "$RESULT" "Removed contact $JID"
