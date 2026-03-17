#!/bin/bash
# Shared helper functions for ducko-ui automation scripts.
# Source this file: source "$SCRIPT_DIR/ducko-helpers.sh"
#
# AppleScript snippet generators output code for use inside a
# `tell process "DuckoApp"` block. The calling script uses an unquoted
# heredoc (<< APPLESCRIPT) so that $() expansions are evaluated by the shell.

# --- AppleScript snippet generators ---

# Find a window containing an element with the given AXIdentifier.
# Sets the AppleScript variable $var_name (default: targetWin).
# Args: identifier [error_msg] [var_name]
ducko_as_find_window_by_id() {
    local identifier="$1"
    local error_msg="${2:-window not found}"
    local var_name="${3:-targetWin}"
    cat << EOF
            set ${var_name} to missing value
            repeat with win in windows
                set allElems to entire contents of win
                repeat with elem in allElems
                    try
                        if value of attribute "AXIdentifier" of elem is "${identifier}" then
                            set ${var_name} to win
                            exit repeat
                        end if
                    end try
                end repeat
                if ${var_name} is not missing value then exit repeat
            end repeat
            if ${var_name} is missing value then return "ERROR: ${error_msg}"
EOF
}

# Find an element by AXIdentifier within a window variable.
# The id_expr is an AppleScript expression: a quoted string like "\"foo\""
# or a variable name like targetId.
# Sets the AppleScript variable $var_name (default: targetElem).
# Args: id_expr window_var [error_msg] [var_name]
ducko_as_find_element_by_id() {
    local id_expr="$1"
    local window_var="${2:-targetWin}"
    local error_msg="${3:-element not found}"
    local var_name="${4:-targetElem}"
    cat << EOF
            set ${var_name} to missing value
            set allElems to entire contents of ${window_var}
            repeat with elem in allElems
                try
                    if value of attribute "AXIdentifier" of elem is ${id_expr} then
                        set ${var_name} to elem
                        exit repeat
                    end if
                end try
            end repeat
            if ${var_name} is missing value then return "ERROR: ${error_msg}"
EOF
}

# Click an element found by AXIdentifier. Combines find + click.
# Args: id_expr window_var [error_msg]
ducko_as_click_element_by_id() {
    local id_expr="$1"
    local window_var="${2:-targetWin}"
    local error_msg="${3:-button not found}"
    ducko_as_find_element_by_id "$id_expr" "$window_var" "$error_msg" "clickTarget"
    echo "            click clickTarget"
}

# Right-click an element and select a named menu item.
# Args: menu_item_name source_var [window_var] [error_msg]
ducko_as_click_context_menu_item() {
    local menu_item_name="$1"
    local source_var="${2:-targetElem}"
    local window_var="${3:-targetWin}"
    local error_msg="${4:-${menu_item_name} menu item not found}"
    cat << EOF
            perform action "AXShowMenu" of ${source_var}
            delay 0.5
            set allElems to entire contents of ${window_var}
            repeat with elem in allElems
                try
                    if role of elem is "AXMenuItem" and name of elem is "${menu_item_name}" then
                        click elem
                        return "ok"
                    end if
                end try
            end repeat
            return "ERROR: ${error_msg}"
EOF
}

# Navigate a file picker via Cmd+Shift+G.
# The path_var is an AppleScript variable name holding the file path.
# Args: path_var
ducko_as_navigate_file_picker() {
    local path_var="$1"
    cat << EOF
            delay 1.5
            keystroke "g" using {command down, shift down}
            delay 1
            keystroke ${path_var}
            delay 0.5
            keystroke return
            delay 1
            keystroke return
            delay 2
EOF
}

# --- Bash utility functions ---

# Standard result handler. Prints success message or error and exits.
# Args: result success_msg
ducko_check_result() {
    local result="$1"
    local success_msg="$2"
    if [[ "$result" == ok ]]; then
        echo "$success_msg"
    else
        echo "$result" >&2
        exit 1
    fi
}
