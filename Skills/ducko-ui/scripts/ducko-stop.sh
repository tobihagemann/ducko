#!/bin/bash
# Kill every DuckoApp this checkout built, whether launched by `swift run` or from its packaged bundle.
# Usage: ducko-stop.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && cd "$(pwd -P)/../../.." && pwd)"

# Matches only this checkout's executables, so an installed production app (also named DuckoApp) keeps running.
# `swift run` launches the build product by its path relative to the checkout.
PIDS=$(pgrep -f "^(${ROOT_DIR}/|\./)?(Ducko\.app/Contents/MacOS|\.build/[^ ]*)/DuckoApp( |$)" 2>/dev/null || true)
if [[ -n "$PIDS" ]]; then
    kill $PIDS
    echo "DuckoApp stopped (PIDs: $(echo $PIDS | tr '\n' ' '))"
else
    echo "DuckoApp is not running"
fi
