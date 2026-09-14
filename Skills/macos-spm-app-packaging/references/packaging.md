# Packaging notes

## Build output paths
SwiftPM places binaries under:
- `.build/<arch>-apple-macosx/<config>/<AppName>` for arch-specific builds
- `.build/<config>/<AppName>` for some products (frameworks/tools)

Set `ARCHES="arm64 x86_64"` when running the template scripts to produce universal binaries; plain `swift build` ignores it.

## Common environment variables (used by templates)
- `APP_NAME`: App/binary name (for example, `MyApp`).
- `BUNDLE_ID`: Bundle identifier (for example, `com.example.myapp`).
- `ARCHES`: Space-separated architectures (default: host arch).
- `SIGNING_MODE`: `adhoc` to avoid keychain prompts in dev.
- `APP_IDENTITY`: Codesigning identity name for release builds.
- `MACOS_MIN_VERSION`: Minimum macOS version for Info.plist.
- `MENU_BAR_APP`: Set to `1` to add `LSUIElement` to Info.plist.
