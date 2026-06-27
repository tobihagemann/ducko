#!/bin/bash
# Open the Connection Info sheet from Preferences > Accounts tab.
# Uses script composition to ensure the Accounts tab is active first.
#
# Best-effort: selecting the account row drives a SwiftUI `List(selection:)`,
# which synthetic clicks cannot reliably trigger, and the "Connection Info…"
# button only appears once the account is connected. The button is located via
# findByRoleAndName rather than `entire contents`, which collapses on macOS 26.
# Usage: ducko-connection-info.sh
set -euo pipefail

# Ensure Preferences window is open on the Accounts tab
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ducko-preferences.sh" > /dev/null 2>&1 || true
"$SCRIPT_DIR/ducko-preferences-tab.sh" Accounts > /dev/null 2>&1 || true

RESULT=$(osascript << 'APPLESCRIPT'
on findByRoleAndName(el, roleWanted, nameWanted, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (role of c) is roleWanted and (name of c) is nameWanted then return c
                end try
                set found to my findByRoleAndName(c, roleWanted, nameWanted, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByRoleAndName

on findAccountRow(el, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    set v to value of c
                    if v is not missing value and v contains "@" then return c
                end try
                set found to my findAccountRow(c, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findAccountRow

on run
    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5
        -- Select the first account so the detail pane (with Connection Info) renders.
        repeat with win in (windows of process "DuckoApp")
            set acctRow to my findAccountRow(win, 0, 30)
            if acctRow is not missing value then
                try
                    click acctRow
                end try
                exit repeat
            end if
        end repeat
        delay 0.4

        -- Find the Connection Info… button in any window.
        repeat with win in (windows of process "DuckoApp")
            set btn to my findByRoleAndName(win, "AXButton", "Connection Info...", 0, 30)
            if btn is not missing value then
                click btn
                delay 0.5
                return "ok"
            end if
        end repeat
        return "ERROR: Connection Info... button not found (is the account connected?)"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Connection Info sheet opened"
else
    echo "$RESULT" >&2
    exit 1
fi
