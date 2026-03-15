#!/bin/bash
# View or set the room topic in the active chat window.
# The RoomSubjectView provides inline editing with a pencil button.
# Usage: ducko-room-topic.sh [TEXT]
#   No args: prints the current topic
#   TEXT: set the room topic to TEXT
set -euo pipefail

TEXT="${1:-__none__}"

RESULT=$(osascript - "$TEXT" << 'APPLESCRIPT'
on run argv
    set topicText to item 1 of argv

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

            -- Find the room-subject-view
            set subjectView to missing value
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is "room-subject-view" then
                        set subjectView to elem
                        exit repeat
                    end if
                end try
            end repeat
            if subjectView is missing value then return "ERROR: room-subject-view not found (is this a room?)"

            -- Read mode: return the current topic text
            if topicText is "__none__" then
                set subjectElems to entire contents of subjectView
                repeat with elem in subjectElems
                    try
                        if role of elem is "AXStaticText" then
                            return value of elem
                        end if
                    end try
                end repeat
                return "No topic set"
            end if

            -- Edit mode: click the pencil edit button
            set pencilClicked to false
            set subjectElems to entire contents of subjectView
            repeat with elem in subjectElems
                try
                    if role of elem is "AXButton" then
                        click elem
                        set pencilClicked to true
                        exit repeat
                    end if
                end try
            end repeat
            if not pencilClicked then return "ERROR: edit button not found in room-subject-view"
            delay 0.3

            -- Find the text field that appears within the subject view after clicking edit
            set filled to false
            set subjectElems to entire contents of subjectView
            repeat with elem in subjectElems
                try
                    if role of elem is "AXTextField" then
                        set focused of elem to true
                        delay 0.2
                        keystroke "a" using command down
                        delay 0.1
                        keystroke topicText
                        set filled to true
                        exit repeat
                    end if
                end try
            end repeat
            if not filled then return "ERROR: topic text field not found"
            delay 0.3

            -- Find and click the Save button
            set allElems to entire contents of chatWin
            repeat with elem in allElems
                try
                    if role of elem is "AXButton" and name of elem is "Save" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: Save button not found"
        end tell
    end tell
end run
APPLESCRIPT
)

case "$RESULT" in
    ok)     echo "Room topic set" ;;
    ERROR*) echo "$RESULT" >&2; exit 1 ;;
    *)      echo "Topic: $RESULT" ;;
esac
