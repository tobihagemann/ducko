#!/bin/bash
# Switch to Import mode on the Welcome screen and click Import.
# The Import tab is the default on a fresh launch, so this script
# only needs to click the Import button after passwords are entered
# (password entry is interactive and not automated here).
# Usage: ducko-import.sh
set -euo pipefail

RESULT=$(osascript << 'APPLESCRIPT'
tell application "System Events"
    set frontmost of process "DuckoApp" to true
    delay 1
    tell process "DuckoApp"
        set allElems to entire contents of window "Welcome"

        -- Ensure Import tab is selected
        repeat with elem in allElems
            try
                if value of attribute "AXIdentifier" of elem is "setup-mode-picker" then
                    set segElems to entire contents of elem
                    repeat with seg in segElems
                        try
                            if name of seg is "Import" then
                                click seg
                                exit repeat
                            end if
                        end try
                    end repeat
                    exit repeat
                end if
            end try
        end repeat
        delay 0.5

        -- Re-read elements after mode switch
        set allElems to entire contents of window "Welcome"

        -- Click the import button
        repeat with elem in allElems
            try
                set elemId to value of attribute "AXIdentifier" of elem
                if elemId is "import-button" then
                    click elem
                    return "ok"
                end if
            end try
        end repeat
        return "ERROR: import-button not found"
    end tell
end tell
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Import initiated"
else
    echo "$RESULT" >&2
    exit 1
fi
