# Ducko

A native macOS XMPP client — spiritual successor to Adium.

## Tech Stack

- Swift 6.2, macOS 26+, SwiftPM (no Xcode project)
- SwiftUI, SwiftData, Sparkle
- Custom XMPP implementation (no libpurple, no XMPPFramework)
- All types use Swift strict concurrency (`Sendable`, actors, structured concurrency)

## Module Boundaries

```
DuckoXMPP   # standalone XMPP library, zero internal deps
DuckoCore   # depends on DuckoXMPP only
DuckoData   # depends on DuckoCore
DuckoUI     # depends on DuckoCore
DuckoApp    # depends on all + Sparkle
```

These boundaries are strict:
- DuckoXMPP must never import other Ducko modules
- DuckoCore must never import DuckoData or DuckoUI
- DuckoUI must never import DuckoData

## Build & Test

```
swift build
swift test
swift test --filter DuckoXMPPTests   # run a specific test target
```

Always use `dangerouslyDisableSandbox: true` for `swift build` and `swift test` commands.

## Code Conventions

- **No Objective-C**: pure Swift, no `@objc`, no NSObject subclasses
- **Value types preferred**: structs and enums over classes, except where reference semantics are required (`@Observable`, `@Model`, actors)
- **XMLElement naming**: our `XMLElement` struct (in DuckoXMPP) conflicts with Foundation's `NSXMLElement`. Do not `import Foundation` in files that use `XMLElement` directly. Use stdlib alternatives instead of Foundation string helpers in those files.
- **Testing**: use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest. Struct-based suites, parameterized tests via `@Test(arguments:)`.
- **Concurrency**: value types (struct/enum) are automatically `Sendable`. Never use `@unchecked Sendable`. Use actors for mutable shared state.