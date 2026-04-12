# Ducko

A native macOS XMPP client — spiritual successor to Adium.

## Tech Stack

- Swift 6.2, macOS 26+, SwiftPM (no Xcode project)
- SwiftUI, SwiftData (metadata only), Sparkle
- Custom XMPP implementation (no libpurple, no XMPPFramework)
- All types use Swift strict concurrency (`Sendable`, actors, structured concurrency)
- Messages stored as append-only JSONL transcript files (`FileTranscriptStore`), not SwiftData

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

## Feature Parity

DuckoApp (GUI) and DuckoCLI (CLI) are independent consumers of DuckoCore. When adding features:

- **CLI formatters**: Update `ANSIFormatter`, `PlainFormatter`, and `JSONFormatter` for any new `XMPPEvent` cases or changed event semantics.
- **REPL commands**: Add corresponding REPL commands (e.g., `/pm`, `/moderate`) when the GUI gets new interactive features.
- **ducko-ui scripts**: Add automation scripts in `Skills/ducko-ui/scripts/` for new UI elements (buttons, context menu items, sheets). Update the ducko-ui skill's script inventory and accessibility identifier list.

## Build & Test

```
swift build
swift build --build-tests            # compile test targets without running them
swift test
swift test --filter DuckoXMPPTests   # run a specific test target
swift run DuckoApp                   # run GUI
swift run DuckoCLI                   # run CLI
```

Note: `swift build` only compiles executable and library targets. Use `swift build --build-tests` to verify test target compilation.

After `swift build`, binaries are directly runnable from `.build/debug/` (e.g., `.build/debug/DuckoCLI`).

### Integration Tests

Integration tests in `DuckoIntegrationTests` run against a live XMPP server. They skip automatically when credentials are not set.

```
source .env.test && swift test --filter DuckoIntegrationTests.ProtocolLayer
```

## Packaging

`version.env` is the single source of truth for app metadata (`APP_NAME`, `BUNDLE_ID`, `EXEC_NAME`, `CLI_NAME`). All scripts source it.

```
Scripts/package_app.sh [debug|release]   # build + assemble .app bundle
Scripts/compile_and_run.sh               # package + launch (dev loop)
Scripts/create_dmg.sh                    # wrap .app in DMG
Scripts/release.sh                       # build, sign, notarize, DMG, zip
```

`Resources/Entitlements.plist` holds app entitlements. `Resources/Assets.car` is the precompiled Liquid Glass icon.

## Logging

Uses `swift-log` as a facade with dual backends:

- **OSLog backend** (`OSLogHandler`) — forwards to Apple's unified logging for Console.app/Xcode debugging
- **File backend** (`FileLogHandler`) — writes to `~/Library/Application Support/<app-dir>/Logs/ducko.log` with size-based rotation (5 MB, 5 archives)

Logger labels use dot notation: `Logger(label: "im.ducko.xmpp.client")` — last component is the category (flat lowercase), rest is the subsystem.

`LoggingConfiguration.bootstrap()` is called once at launch (DuckoApp.init / CLIBootstrap.setUp). File log verbosity is controlled by the `advancedLogLevel` UserDefaults key (UI: Preferences > Advanced > Log Level) — "default" → info, "debug" → debug, "verbose" → trace.

**Privacy policy**: error/warning/info/notice must never contain sensitive data (passwords, tokens, keys). Only debug/trace may contain JIDs, stanza fragments. Ultra-sensitive data is never logged.

**Export**: `ducko logs` CLI subcommand, Help > Export Logs... in GUI.

## Dev/Prod Isolation

`BuildEnvironment` (in DuckoCore) centralizes `#if DEBUG` config. Debug builds use separate storage to avoid polluting production data:

| Component | Prod | Dev |
|-----------|------|-----|
| SwiftData (metadata) | `~/Library/Application Support/Ducko/` | `~/Library/Application Support/Ducko-Dev/` |
| Transcripts (JSONL) | `~/Library/Application Support/Ducko/Transcripts/` | `~/Library/Application Support/Ducko-Dev/Transcripts/` |
| Credentials | macOS Keychain | `Ducko-Dev/credentials.json` (file-based) |
| UserDefaults | `.standard` | `UserDefaults(suiteName: "im.ducko.dev")` |

Set `DUCKO_USE_KEYCHAIN=1` to use real Keychain in debug builds.

Set `DUCKO_PROFILE=<name>` to run multiple isolated instances side by side:

| Component | Default Dev | `DUCKO_PROFILE=alice` |
|-----------|-------------|----------------------|
| SwiftData (metadata) | `Ducko-Dev/` | `Ducko-Dev-alice/` |
| Transcripts (JSONL) | `Ducko-Dev/Transcripts/` | `Ducko-Dev-alice/Transcripts/` |
| Credentials | `Ducko-Dev/credentials.json` | `Ducko-Dev-alice/credentials.json` |
| UserDefaults | `im.ducko.dev` | `im.ducko.dev.alice` |

## Lint & Format

SwiftFormat, SwiftLint, and Periphery are installed via Homebrew:

```
./Scripts/format.sh            # Auto-format + autocorrect
./Scripts/lint.sh              # Check format + lint + unused code (read-only)
```

## Agent Skills

All project-visible agent skills live under `Skills/`. `.claude/skills` and `.agents/skills` are single top-level symlinks pointing at `../Skills`, so adding a new skill is just `mkdir Skills/<name>` — nothing else to wire up.

The set is a mix of:

- **Ducko-original skills** — written for this repo (`create-dmg`, `ducko-cli`, `ducko-ui`, `macos-ui-testing`, `package-app`, `release`, `smoke-test-party`).
- **Upstream-derived skills** — merged from open-source agent skills from [twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/SwiftUI-Agent-Skill) and related catalogs (`swiftui`, `swiftdata`, `swift-concurrency`, `swift-testing`, `swift-language`, `swift-architecture`, `swift-security`, `swiftui-performance-audit`, `accessibility`, `writing-for-interfaces`, `macos-spm-app-packaging`).

See `Skills/ATTRIBUTION.md` for per-skill upstream sources and MIT copyright notices.

## Code Conventions

- **No Objective-C**: pure Swift, no `@objc`, no NSObject subclasses
- **Value types preferred**: structs and enums over classes, except where reference semantics are required (`@Observable`, `@Model`, actors)
- **XMLElement naming**: our `XMLElement` struct (in DuckoXMPP) conflicts with Foundation's `NSXMLElement`. In DuckoXMPP files, do not `import Foundation` — use stdlib alternatives instead. In DuckoCore files (which always import Foundation), use `DuckoXMPP.XMLElement` to disambiguate.
- **Testing**: use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest. Struct-based suites, parameterized tests via `@Test(arguments:)`.
- **Concurrency**: value types (struct/enum) are automatically `Sendable`. Never use `@unchecked Sendable`. Use actors for mutable shared state.
- **libxml2 / CLibxml2**: DuckoXMPP uses libxml2 via a `CLibxml2` system library target (`Sources/CLibxml2/`). For C callbacks that need a back-reference to a Swift class, use the `Unmanaged.passUnretained(self).toOpaque()` pattern — do not use NSObject or `@objc`.
- **CryptoKit**: Does not re-export Foundation on macOS 26. Safe to import alongside `XMLElement` without naming conflicts. `DataProtocol` is defined in Foundation — CryptoKit's `HashFunction.hash(data:)` requires it but importing CryptoKit alone does not bring `DataProtocol` into scope. In DuckoXMPP, use `[UInt8]` instead of `some DataProtocol` for function parameters.
- **Exhaustive switches**: Never use `default:` when switching on project-defined enums. List all cases explicitly so the compiler catches new cases at build time.
