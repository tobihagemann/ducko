#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/ducko-preferences.sh"
"$SCRIPT_DIR/ducko-preferences-tab.sh" General
"$SCRIPT_DIR/ducko-toggle-preference.sh" showInMenuBarToggle
