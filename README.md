# Ducko

A modern macOS XMPP client – spiritual successor to Adium.

Ducko carries forward the spirit of Adium: personality-driven, deeply customizable, and unapologetically Mac-native. Where Adium unified dozens of protocols through libpurple, Ducko starts focused on XMPP and builds outward from a modern Swift foundation.

## Requirements

- macOS 26+
- Swift 6.2+

## Building

```
swift build
```

## Running

```
swift run DuckoApp    # GUI
swift run DuckoCLI    # CLI
```

## Testing

```
swift test
```

## Code Style

[SwiftFormat](https://github.com/nicklockwood/SwiftFormat) and [SwiftLint](https://github.com/realm/SwiftLint) enforce code style. Install both via Homebrew:

```
brew install swiftlint swiftformat
```

Set up the pre-commit hook (run once after cloning):

```
./Scripts/install-hooks.sh
```

Run manually:

```
./Scripts/lint.sh              # Format + autocorrect + lint all files
./Scripts/lint.sh --check      # Check-only mode (CI)
```

## Agent Skills

Project-specific [agent skills](https://agentskills.io/) live in `Skills/`. See individual `SKILL.md` files for details.

## Architecture

Six SwiftPM modules with clear dependency boundaries:

```
DuckoXMPP  (standalone XMPP protocol implementation)
    ^
    |
DuckoCore  (domain types, services, business logic)
    ^            ^            ^
    |            |            |
DuckoData    DuckoUI      DuckoCLI  (+ swift-argument-parser)
    ^            ^
    |            |
    +-- DuckoApp --+  (+ Sparkle)
```

| Module | Purpose |
|--------|---------|
| **DuckoXMPP** | Standalone, reusable XMPP library. Connection, stream parsing, SASL auth, stanza types, JID types, XEP modules. |
| **DuckoCore** | Domain layer. Account/Contact/Conversation types, service objects, message filter pipeline. |
| **DuckoData** | Persistence layer. SwiftData models, migration logic, query helpers. |
| **DuckoUI** | View layer. SwiftUI views, view models, theme engine, window management. |
| **DuckoApp** | GUI entry point. Dependency wiring, menu bar, Sparkle updates, lifecycle. |
| **DuckoCLI** | CLI entry point. Subcommands, interactive REPL, terminal output formatting. |

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Platform | macOS only | Focus. Adium was Mac-only and beloved for it. |
| Language | Swift 6.2 | Latest concurrency features, strict sendability |
| Protocol | XMPP only (v1) | Start focused, expand later |
| Build system | SwiftPM | No Xcode project. Clean, reproducible builds. |
| Distribution | Direct (Sparkle) | No App Store sandbox constraints |
| Persistence | SwiftData | Modern, declarative, Swift-native |
| UI | SwiftUI + separate windows | Adium-style multi-window UX |
| CLI | swift-argument-parser | Scriptable + interactive access alongside GUI |

## License

Distributed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.
