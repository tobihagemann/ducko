---
name: release
description: Prepare and publish a Ducko release. Build, sign, notarize, create DMG, generate Sparkle appcast, and publish to GitHub. Use when asked to "cut a release", "publish a new version", "bump the version", "prepare a release", or "ship it".
---

# Release

All script invocations require `dangerouslyDisableSandbox: true`.

## Step 1: Bump Version

Update `version.env`:
- `MARKETING_VERSION` — user-facing version (e.g., `0.2.0`)
- `BUILD_NUMBER` — must increase for every release (Sparkle requirement)

Commit the version bump.

## Step 2: Build, Sign, Notarize

```bash
source .env.local
./Scripts/release.sh     # produces Ducko-x.y.z.zip + Ducko-x.y.z.dmg
```

## Step 3: Generate Appcast

```bash
.build/arm64-apple-macosx/debug/Sparkle.framework/bin/generate_appcast /path/to/releases/
```

This reads signed zips and creates/updates `appcast.xml`.

## Step 4: Publish

```bash
git tag v0.x.y
gh release create v0.x.y Ducko-0.x.y.dmg Ducko-0.x.y.zip
```

Commit and push `appcast.xml` so Sparkle can find the new release.

## Notes

- `release.sh` calls `package_app.sh` and `create_dmg.sh` internally — do not run them separately.
- See the Packaging section in CLAUDE.md for the full script inventory.
