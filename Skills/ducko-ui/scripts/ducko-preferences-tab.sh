#!/bin/bash
# Switch to a specific tab in the Preferences (Settings) window.
# The Preferences window must already be open (use ducko-preferences.sh first).
# Note: macOS titles this window after the selected tab (e.g. "General", "Accounts").
# Usage: ducko-preferences-tab.sh <General|Accounts|Appearance|Notifications|Advanced>
set -euo pipefail

TAB="${1:?Usage: ducko-preferences-tab.sh <General|Accounts|Appearance|Notifications|Advanced>}"

RESULT=$(osascript - "$TAB" << 'APPLESCRIPT'
on run argv
    set tabName to item 1 of argv
    set tabNames to {"General", "Accounts", "Appearance", "Notifications", "Advanced"}
    if tabName is not in tabNames then return "ERROR: unknown tab: " & tabName
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.3
        tell process "DuckoApp"
            -- Find the Settings window (titled after the active tab).
            -- Verify via toolbar buttons to distinguish from chat windows with the same title.
            set settingsWin to missing value
            repeat with win in windows
                if name of win is in tabNames then
                    set isSettings to false
                    try
                        set tbElems to entire contents of toolbar 1 of win
                        repeat with elem in tbElems
                            try
                                if role of elem is "AXButton" and name of elem is in tabNames then
                                    set isSettings to true
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end try
                    if isSettings then
                        set settingsWin to win
                        exit repeat
                    end if
                end if
            end repeat
            if settingsWin is missing value then return "ERROR: Settings window not found (open it with ducko-preferences.sh first)"
            perform action "AXRaise" of settingsWin

            -- Click the tab button in the toolbar
            try
                set tb to toolbar 1 of settingsWin
                set allTbElems to entire contents of tb
                repeat with elem in allTbElems
                    try
                        if role of elem is "AXButton" and name of elem is tabName then
                            click elem
                            delay 0.3
                            return "ok"
                        end if
                    end try
                end repeat
            end try

            -- Fallback: search entire window contents for a button with the tab name
            set allElems to entire contents of settingsWin
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and name of elem is tabName then
                        click elem
                        delay 0.3
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: tab " & tabName & " not found"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Switched to tab: $TAB"
else
    echo "$RESULT" >&2
    exit 1
fi
