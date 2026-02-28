#!/bin/bash
# Reconnect a running DuckoApp by restarting it.
# The app auto-connects on launch if Keychain credentials exist.
# Usage: ducko-connect.sh
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPTS_DIR/ducko-stop.sh"
sleep 1
"$SCRIPTS_DIR/ducko-launch.sh"
