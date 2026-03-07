#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_BUNDLE="$ROOT/${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"

if [[ -z "${APP_IDENTITY:-}" ]]; then
  echo "APP_IDENTITY env var must be set (e.g., 'Developer ID Application: Name (TEAMID)')." >&2
  exit 1
fi

if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars (API key, key id, issuer id)." >&2
  exit 1
fi

echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > /tmp/app-store-connect-key.p8
chmod 600 /tmp/app-store-connect-key.p8
trap 'rm -f /tmp/app-store-connect-key.p8 /tmp/${APP_NAME}Notarize.zip' EXIT

ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
APP_IDENTITY="$APP_IDENTITY" ARCHES="${ARCHES_VALUE}" "$ROOT/Scripts/package_app.sh" release

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "/tmp/${APP_NAME}Notarize.zip"

xcrun notarytool submit "/tmp/${APP_NAME}Notarize.zip" \
  --key /tmp/app-store-connect-key.p8 \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

xcrun stapler staple "$APP_BUNDLE"

# Strip extended attributes and AppleDouble files that stapling may leave behind.
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

spctl -a -t exec -vv "$APP_BUNDLE"
stapler validate "$APP_BUNDLE"

# Create, sign, and notarize the DMG.
"$ROOT/Scripts/create_dmg.sh"
DMG_NAME="${APP_NAME}-${MARKETING_VERSION}.dmg"
codesign --force --timestamp --sign "$APP_IDENTITY" "$ROOT/$DMG_NAME"

"$DITTO_BIN" --norsrc -c -k "$ROOT/$DMG_NAME" "/tmp/${APP_NAME}Notarize.zip"
xcrun notarytool submit "/tmp/${APP_NAME}Notarize.zip" \
  --key /tmp/app-store-connect-key.p8 \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait
xcrun stapler staple "$ROOT/$DMG_NAME"

echo "Done: $ZIP_NAME, $DMG_NAME"
