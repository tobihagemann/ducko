# Local Release (Fallback)

Use this procedure only when GitHub Actions CI is unavailable.

All commands require `dangerouslyDisableSandbox: true`.

## Prerequisites

Set environment variables (e.g., in `.env.local`):

```bash
export APP_IDENTITY="Developer ID Application: Name (TEAMID)"
export APP_STORE_CONNECT_API_KEY_P8="$(cat /path/to/AuthKey_XXXX.p8)"
export APP_STORE_CONNECT_KEY_ID="XXXXXXXXXX"
export APP_STORE_CONNECT_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## Steps

### 1. Update CHANGELOG.md

Add release notes to `CHANGELOG.md` under a new `## x.y.z` heading.

### 2. Tag

```bash
git add CHANGELOG.md
git commit -m "Prepare release x.y.z"
git tag x.y.z
```

### 3. Build, Sign, and Notarize

```bash
source .env.local
./Scripts/release.sh
```

This produces `Ducko-x.y.z.zip` and `Ducko-x.y.z.dmg` (both signed, notarized, and stapled).

### 4. Generate Appcast

```bash
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

RELEASE_DIR=$(mktemp -d)
cp Ducko-x.y.z.zip "$RELEASE_DIR/"

"$SPARKLE_BIN/generate_appcast" \
  --ed-key-file /path/to/sparkle_private.key \
  --download-url-prefix "https://github.com/tobihagemann/ducko/releases/download/x.y.z/" \
  "$RELEASE_DIR"

cp "$RELEASE_DIR/appcast.xml" appcast.xml
rm -rf "$RELEASE_DIR"
```

The private key is in the macOS Keychain (stored by `generate_keys`). Export with:

```bash
"$SPARKLE_BIN/generate_keys" -x /path/to/sparkle_private.key
```

### 5. Publish

```bash
git add appcast.xml
git commit -m "Update appcast.xml for x.y.z"
git push origin main x.y.z

gh release create x.y.z \
  Ducko-x.y.z.zip \
  Ducko-x.y.z.dmg \
  --title "Ducko x.y.z" \
  --notes-file <(awk -v ver="x.y.z" '/^## / { if (found) exit; if ($2 == ver) found=1; next } found { print }' CHANGELOG.md)
```
