---
name: create-dmg
description: "Create a DMG disk image from the packaged Ducko.app. Use when the user asks to \"create a DMG\", \"make a DMG\", \"build a DMG\", \"package DMG\", or \"create disk image\"."
---

# Create DMG

Run `Scripts/create_dmg.sh` to wrap the existing `Ducko.app` into a DMG with an Applications symlink.

```bash
./Scripts/create_dmg.sh
```

Prerequisite: `Ducko.app` must exist at the project root. If it doesn't, run `/package-app release` first.

The script requires disabling the Claude Code sandbox (`dangerouslyDisableSandbox: true`) because `hdiutil` needs to create and mount disk images.

The output `Ducko-<version>.dmg` is placed at the project root (version from the latest git tag, or `0.0.0` if untagged).
