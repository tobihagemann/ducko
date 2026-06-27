#!/bin/bash
# Switch to Import mode on the Welcome screen and click Import.
# The Import tab is the default on a fresh launch, so this script
# only needs to click the Import button after passwords are entered
# (password entry is interactive and not automated here).
#
# Walks the Welcome window's UI-element tree via findByAttr rather than
# `entire contents`, which collapses on the deeply-nested SwiftUI hierarchy on
# macOS 26. The segmented Picker exposes the Import label via AXDescription.
# import-button exists only in the data-found branch of the Import view; the
# no-data branch instead exposes choose-adium-folder-button.
# Usage: ducko-import.sh
set -euo pipefail

RESULT=$(osascript << 'APPLESCRIPT'
on findByAttr(el, attrName, attrValue, depth, maxDepth)
    tell application "System Events"
        if depth > maxDepth then return missing value
        try
            repeat with c in (UI elements of el)
                try
                    if (value of attribute attrName of c) is attrValue then return c
                end try
                set found to my findByAttr(c, attrName, attrValue, depth + 1, maxDepth)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByAttr

on run
    tell application "System Events"
        if not (exists process "DuckoApp") then return "ERROR: DuckoApp is not running"
        set proc to process "DuckoApp"
        set frontmost of proc to true
        delay 1
        if not (exists window "Welcome" of proc) then return "ERROR: Welcome window not found"
        set win to window "Welcome" of proc

        -- Ensure the Import segment is selected.
        set picker to my findByAttr(win, "AXIdentifier", "setup-mode-picker", 0, 30)
        if picker is missing value then return "ERROR: setup-mode-picker not found"
        set seg to my findByAttr(picker, "AXDescription", "Import", 0, 6)
        if seg is missing value then return "ERROR: Import segment not found"
        click seg
        delay 0.5

        -- Click the import button (present only when Adium data was discovered).
        set importBtn to my findByAttr(win, "AXIdentifier", "import-button", 0, 30)
        if importBtn is missing value then return "ERROR: import-button not found (no Adium data discovered?)"
        click importBtn
        return "ok"
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Import initiated"
else
    echo "$RESULT" >&2
    exit 1
fi
