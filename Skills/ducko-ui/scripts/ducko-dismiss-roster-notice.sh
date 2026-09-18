#!/bin/bash
# Usage: DUCKO_PID=<pid> ducko-dismiss-roster-notice.sh [contacts|info]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "${1:-contacts}" in
    contacts) NOTICE_ID="roster-notice" ;;
    info) NOTICE_ID="contact-info-roster-notice" ;;
    *) echo "Usage: ducko-dismiss-roster-notice.sh [contacts|info]" >&2; exit 1 ;;
esac
APP_PID="${DUCKO_PID:-}"
if [[ -z "$APP_PID" ]]; then
    APP_PID=$(pgrep -x DuckoApp || true)
fi
if [[ ! "$APP_PID" =~ ^[0-9]+$ ]]; then
    echo "Set DUCKO_PID to the intended Ducko instance's PID." >&2
    exit 1
fi
exec swift "$SCRIPT_DIR/ducko-dismiss.swift" "$APP_PID" "$NOTICE_ID" "Dismiss notice"
