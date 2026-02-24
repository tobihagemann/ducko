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
swift run Ducko
```

## Testing

```
swift test
```

## Architecture

Five SwiftPM modules with clear dependency boundaries:

```
DuckoXMPP  (standalone XMPP protocol implementation)
    ^
    |
DuckoCore  (domain types, services, business logic)
    ^            ^
    |            |
DuckoData    DuckoUI
    ^            ^
    |            |
    +-- DuckoApp --+  (app entry point + Sparkle)
```

| Module | Purpose |
|--------|---------|
| **DuckoXMPP** | Standalone, reusable XMPP library. Connection, stream parsing, SASL auth, stanza types, JID types, XEP modules. |
| **DuckoCore** | Domain layer. Account/Contact/Conversation types, service objects, message filter pipeline. |
| **DuckoData** | Persistence layer. SwiftData models, migration logic, query helpers. |
| **DuckoUI** | View layer. SwiftUI views, view models, theme engine, window management. |
| **DuckoApp** | App entry point. Dependency wiring, menu bar, Sparkle updates, lifecycle. |

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

## License

Distributed under the GNU General Public License v3.0. See the [LICENSE](LICENSE) file for details.
