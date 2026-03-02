#!/bin/bash
# Open the View Options menu in the contact list toolbar.
# Optionally select a sort mode or toggle Hide Offline.
# Usage: ducko-sort.sh [alphabetical|byStatus|recentConversation|hideOffline]
#   No args:         opens the menu (for visual verification)
#   alphabetical:    select "Alphabetical" sort
#   byStatus:        select "By Status" sort
#   recentConversation: select "Recent Conversation" sort
#   hideOffline:     toggle "Hide Offline"
set -euo pipefail

ACTION="${1:-__none__}"

RESULT=$(osascript - "$ACTION" << 'APPLESCRIPT'
on run argv
    set sortAction to item 1 of argv
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find and raise the Contacts window
            set contactWin to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "contact-list" then
                            set contactWin to win
                            exit repeat
                        end if
                    end try
                end repeat
                if contactWin is not missing value then exit repeat
            end repeat
            if contactWin is missing value then return "ERROR: Contacts window not found"
            perform action "AXRaise" of contactWin
            delay 0.3

            -- Map sortAction to the menu item label (early, before opening menus)
            set targetLabel to ""
            if sortAction is not "__none__" then
                if sortAction is "alphabetical" then
                    set targetLabel to "Alphabetical"
                else if sortAction is "byStatus" then
                    set targetLabel to "By Status"
                else if sortAction is "recentConversation" then
                    set targetLabel to "Recent Conversation"
                else if sortAction is "hideOffline" then
                    set targetLabel to "Hide Offline"
                else
                    return "ERROR: unknown sortAction: " & sortAction
                end if
            end if

            -- Open the View Options menu.
            -- Strategy 1: toolbar is wide enough → AXMenuButton visible directly
            set menuBtn to missing value
            try
                set tb to toolbar 1 of contactWin
                set allTbElems to entire contents of tb
                repeat with elem in allTbElems
                    try
                        if role of elem is "AXMenuButton" then
                            -- Exclude status-picker (also an AXMenuButton in the window)
                            set elemDesc to description of elem
                            if elemDesc is "menu button" then
                                set menuBtn to elem
                                click elem
                                exit repeat
                            end if
                        end if
                    end try
                end repeat
            end try

            -- Strategy 2: toolbar overflow → click popup, menu tree appears inline
            set overflowClicked to false
            if menuBtn is missing value then
                try
                    set tb to toolbar 1 of contactWin
                    set tbItems to UI elements of tb
                    repeat with item_ref in tbItems
                        try
                            if description of item_ref is "more toolbar items" then
                                click item_ref
                                delay 0.5
                                set overflowClicked to true
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
            end if

            if menuBtn is missing value and not overflowClicked then
                return "ERROR: View Options menu not found"
            end if

            delay 0.3

            if sortAction is "__none__" then return "menu-opened"

            -- Find and click the target menu item.
            -- Strategy 1 opens a dropdown from AXMenuButton → search its menu.
            -- Strategy 2 opens overflow → menu items appear in window contents.
            if menuBtn is not missing value then
                -- Dropdown menu from the toolbar button
                try
                    set menuElems to entire contents of menu 1 of menuBtn
                    repeat with elem in menuElems
                        try
                            if role of elem is "AXMenuItem" and name of elem is targetLabel then
                                click elem
                                return "ok"
                            end if
                        end try
                    end repeat
                end try
            end if

            -- Fallback: search window contents (covers overflow and dropdown)
            set allElems to entire contents of contactWin
            repeat with elem in allElems
                try
                    if role of elem is "AXMenuItem" and name of elem is targetLabel then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: menu item " & targetLabel & " not found"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    menu-opened) echo "View Options menu opened" ;;
    ok)          echo "Applied: ${ACTION}" ;;
    *)           echo "$RESULT" >&2; exit 1 ;;
esac
