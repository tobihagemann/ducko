#!/bin/bash
# Trust, untrust, or verify an OMEMO device in the DeviceFingerprintsSheet.
# The fingerprints sheet must already be open (via ducko-encrypt.sh fingerprints).
# Usage: ducko-device-trust.sh DEVICE_ID ACTION
#   DEVICE_ID: the numeric device ID
#   ACTION: trust|untrust|verify
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: ducko-device-trust.sh DEVICE_ID ACTION" >&2
    exit 1
fi

DEVICE_ID="$1"
ACTION="$2"

RESULT=$(osascript - "$DEVICE_ID" "$ACTION" << 'APPLESCRIPT'
on run argv
    set deviceID to item 1 of argv
    set trustAction to item 2 of argv

    -- Map action to button identifier prefix
    set btnPrefix to ""
    if trustAction is "trust" then
        set btnPrefix to "trust-button-"
    else if trustAction is "untrust" then
        set btnPrefix to "untrust-button-"
    else if trustAction is "verify" then
        set btnPrefix to "verify-button-"
    else
        return "ERROR: unknown action (use trust, untrust, or verify)"
    end if

    set targetId to btnPrefix & deviceID

    tell application "System Events"
        set frontmost of process "DuckoApp" to true
        delay 0.5

        tell process "DuckoApp"
            -- Scan entire contents of all windows for the target button
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is targetId then
                            click elem
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "ERROR: button not found for device " & deviceID & " (wrong trust state?)"
        end tell
    end tell
end run
APPLESCRIPT
)

if [[ "$RESULT" == ok ]]; then
    echo "Device $DEVICE_ID: $ACTION"
else
    echo "$RESULT" >&2
    exit 1
fi
