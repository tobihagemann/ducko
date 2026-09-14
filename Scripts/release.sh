#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

export MARKETING_VERSION=${MARKETING_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")}
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

SCRATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ducko-release-XXXXXX")
trap 'rm -rf "$SCRATCH_DIR"' EXIT
chmod 700 "$SCRATCH_DIR"

ASC_KEY_FILE="$SCRATCH_DIR/app-store-connect-key.p8"
(umask 077 && echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$ASC_KEY_FILE")

ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
PACKAGE_APP_SCRIPT=${PACKAGE_APP_SCRIPT:-$ROOT/Scripts/package_app.sh}
CREATE_DMG_SCRIPT=${CREATE_DMG_SCRIPT:-$ROOT/Scripts/create_dmg.sh}

submit_for_notarization() {
  local zip_path="$1"
  xcrun notarytool submit "$zip_path" \
    --key "$ASC_KEY_FILE" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
}

notarize_and_staple() {
  local bundle="$1"
  local zip_path="$2"
  "$DITTO_BIN" --norsrc -c -k --keepParent "$bundle" "$zip_path"
  submit_for_notarization "$zip_path"
  xcrun stapler staple "$bundle"
  # Strip extended attributes and AppleDouble files that stapling may leave behind.
  xattr -cr "$bundle"
  find "$bundle" -name '._*' -delete
}

APP_IDENTITY="$APP_IDENTITY" ARCHES="${ARCHES_VALUE}" \
  "$PACKAGE_APP_SCRIPT" release

notarize_and_staple "$APP_BUNDLE" "$SCRATCH_DIR/${APP_NAME}Notarize.zip"

"$DITTO_BIN" --norsrc -c -k --keepParent "$APP_BUNDLE" "$ROOT/$ZIP_NAME"

spctl -a -t exec -vv "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

# Create, sign, and notarize the DMG.
DMG_NAME="${APP_NAME}-${MARKETING_VERSION}.dmg"
"$CREATE_DMG_SCRIPT"
codesign --force --timestamp --sign "$APP_IDENTITY" "$ROOT/$DMG_NAME"
DMG_NOTARIZE_ZIP="$SCRATCH_DIR/${APP_NAME}DmgNotarize.zip"
"$DITTO_BIN" --norsrc -c -k "$ROOT/$DMG_NAME" "$DMG_NOTARIZE_ZIP"
submit_for_notarization "$DMG_NOTARIZE_ZIP"
xcrun stapler staple "$ROOT/$DMG_NAME"

echo "Done: $ZIP_NAME, $DMG_NAME"
