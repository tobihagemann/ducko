---
name: package-app
description: "Build and assemble the Ducko.app bundle locally. Use when the user asks to \"package the app\", \"build the app\", \"build a .app\", \"build release\", \"build debug\", \"package release\", or \"package debug\"."
---

# Package App

Run `Scripts/package_app.sh` to build and assemble `Ducko.app` at the project root.

```bash
./Scripts/package_app.sh [debug|release]
```

Default is `release`. The first argument selects the Swift build configuration.

The script requires disabling the Claude Code sandbox (`dangerouslyDisableSandbox: true`) because `swift build` uses `sandbox-exec` internally.

The resulting `Ducko.app` is placed at the project root. It is ad-hoc signed unless `APP_IDENTITY` is set.
