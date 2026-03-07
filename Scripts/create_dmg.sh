#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_BUNDLE="$ROOT/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${MARKETING_VERSION}.dmg"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: ${APP_BUNDLE} not found. Run Scripts/package_app.sh first." >&2
  exit 1
fi

cp -R "$APP_BUNDLE" "$TEMP_DIR/"
ln -s /Applications "$TEMP_DIR/Applications"

hdiutil create -volname "$APP_NAME" \
  -srcfolder "$TEMP_DIR" \
  -ov -format UDZO \
  "$ROOT/$DMG_NAME"

echo "Created $ROOT/$DMG_NAME"
