# Ducko

A native macOS XMPP client — spiritual successor to Adium.

## Tech Stack

- Swift 6.2, macOS 26+, SwiftPM (no Xcode project)
- SwiftUI, SwiftData, Sparkle
- Custom XMPP implementation (no libpurple, no XMPPFramework)
- All types use Swift strict concurrency (`Sendable`, actors, structured concurrency)

## Module Boundaries

```
DuckoXMPP   # standalone XMPP library, depends only on CLibxml2 + CDnssd (system libs)
DuckoCore   # depends on DuckoXMPP only
DuckoData   # depends on DuckoCore
DuckoUI     # depends on DuckoCore
DuckoApp    # depends on all + Sparkle
DuckoCLI    # depends on DuckoCore, DuckoData, DuckoXMPP + swift-argument-parser
```

These boundaries are strict:
- DuckoXMPP must never import other Ducko modules
- DuckoCore must never import DuckoData or DuckoUI
- DuckoUI must never import DuckoData or DuckoXMPP
- DuckoCLI must never import DuckoUI or Sparkle

## Build & Test

```
swift build
swift test
swift test --filter DuckoXMPPTests   # run a specific test target
swift run DuckoApp                   # run GUI
swift run DuckoCLI                   # run CLI
```

After `swift build`, binaries are directly runnable from `.build/debug/` (e.g., `.build/debug/DuckoCLI`).

Always use `dangerouslyDisableSandbox: true` for `swift build` and `swift test` commands.

## Packaging

`version.env` is the single source of truth for app metadata (`APP_NAME`, `BUNDLE_ID`, `MARKETING_VERSION`, `EXEC_NAME`, `CLI_NAME`). All scripts source it.

```
Scripts/package_app.sh [debug|release]   # build + assemble .app bundle
Scripts/compile_and_run.sh               # package + launch (dev loop)
Scripts/create_dmg.sh                    # wrap .app in DMG
Scripts/release.sh                       # build, sign, notarize, DMG, zip
```

`Resources/Entitlements.plist` holds app entitlements. `Resources/Assets.car` is the precompiled Liquid Glass icon.

## Dev/Prod Isolation

`BuildEnvironment` (in DuckoCore) centralizes `#if DEBUG` config. Debug builds use separate storage to avoid polluting production data:

| Component | Prod | Dev |
|-----------|------|-----|
| SwiftData | `~/Library/Application Support/Ducko/` | `~/Library/Application Support/Ducko-Dev/` |
| Credentials | macOS Keychain | `Ducko-Dev/credentials.json` (file-based) |
| UserDefaults | `.standard` | `UserDefaults(suiteName: "de.tobiha.ducko.dev")` |

Set `DUCKO_USE_KEYCHAIN=1` to use real Keychain in debug builds.

## Lint & Format

SwiftFormat and SwiftLint are installed via Homebrew. Run via the orchestrator script:

```
./Scripts/lint.sh              # Format + autocorrect + lint all files
./Scripts/lint.sh --check      # Check-only mode (CI)
```

## Agent Skills

Project-specific agent skills live in `Skills/`. Both `.claude/skills/` and `.agents/skills/` contain symlinks pointing there. When creating a new skill, add the `SKILL.md` to `Skills/<name>/` and create symlinks from both directories.

## Code Conventions

- **No Objective-C**: pure Swift, no `@objc`, no NSObject subclasses
- **Value types preferred**: structs and enums over classes, except where reference semantics are required (`@Observable`, `@Model`, actors)
- **XMLElement naming**: our `XMLElement` struct (in DuckoXMPP) conflicts with Foundation's `NSXMLElement`. Do not `import Foundation` in files that use `XMLElement` directly. Use stdlib alternatives instead of Foundation string helpers in those files.
- **Testing**: use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest. Struct-based suites, parameterized tests via `@Test(arguments:)`.
- **Concurrency**: value types (struct/enum) are automatically `Sendable`. Never use `@unchecked Sendable`. Use actors for mutable shared state.
- **libxml2 / CLibxml2**: DuckoXMPP uses libxml2 via a `CLibxml2` system library target (`Sources/CLibxml2/`). For C callbacks that need a back-reference to a Swift class, use the `Unmanaged.passUnretained(self).toOpaque()` pattern — do not use NSObject or `@objc`.
- **CryptoKit**: Does not re-export Foundation on macOS 26. Safe to import alongside `XMLElement` without naming conflicts.
- **Exhaustive switches**: Never use `default:` when switching on project-defined enums. List all cases explicitly so the compiler catches new cases at build time.
