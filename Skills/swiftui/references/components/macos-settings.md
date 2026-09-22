# macOS Settings

## Intent

Use this when building a macOS Settings window backed by SwiftUI's `Settings` scene.

## Core patterns

- Declare the Settings scene in the `App` and compile it only for macOS.
- Keep settings content in a dedicated root view (`SettingsView`) and drive values with `@AppStorage`.
- Use `TabView` with the `Tab(_:systemImage:)` builder to group settings sections when you have more than one category. `.tabItem` is deprecated.
- Give each pane its own height, so the window resizes to the pane the HIG way.
- Keep one shared width on the `TabView`. The toolbar is centered, so a per-pane width shifts every pane button sideways as the user switches.
- A pane that pairs a list with a detail view (accounts, for example) puts a bordered `List` with a +/− bar next to the detail. A split view adds a draggable divider a fixed-size settings window has no use for, and `HSplitView` draws under the toolbar.
- Use `Form` inside each tab to keep controls aligned and accessible.
- Use `OpenSettingsAction` or `SettingsLink` for in-app entry points to the Settings window.
- There is no sidebar or System Settings-style `Settings` API: as of macOS 27 the HIG prescribes the toolbar-pane window.
- `.pickerStyle(.tabs)` (`TabsPickerStyle`, macOS 27+) is for tab-like pickers inside a view, not a replacement for the Settings toolbar tabs. Gate it with `#available(macOS 27, *)`.

## Example: settings scene

```swift
@main
struct MyApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    #if os(macOS)
    Settings {
      SettingsView()
    }
    #endif
  }
}
```

## Example: tabbed settings view

```swift
@MainActor
struct SettingsView: View {
  @AppStorage("showPreviews") private var showPreviews = true
  @AppStorage("fontSize") private var fontSize = 12.0

  var body: some View {
    TabView {
      Tab("General", systemImage: "gear") {
        Form {
          Toggle("Show Previews", isOn: $showPreviews)
          Slider(value: $fontSize, in: 9...96) {
            Text("Font Size (\(fontSize, specifier: "%.0f") pts)")
          }
        }
        .formStyle(.grouped)
        .frame(height: 200)
      }

      Tab("Advanced", systemImage: "star") {
        Form {
          Toggle("Enable Advanced Mode", isOn: .constant(false))
        }
        .formStyle(.grouped)
        .frame(height: 300)
      }
    }
    .frame(width: 500)
  }
}
```

## Skip navigation

- Avoid wrapping `SettingsView` in a `NavigationStack` unless you truly need deep push navigation.
- Prefer tabs or sections; Settings is already presented as a separate window and should feel flat.

## Pitfalls

- Don’t reuse iOS-only settings layouts (full-screen stacks, toolbar-heavy flows).
- Avoid large custom view hierarchies inside `Form`; keep rows focused and accessible.
- Don't add custom tab persistence: the `Settings` scene saves and restores the selected tab itself. Apple doesn't document how, but on macOS 26 and 27 it writes `com_apple_SwiftUI_Settings_selectedTabIndex` into the app's standard `UserDefaults` domain rather than a custom suite. Since the value is an index, removing or reordering tabs shifts the restored pane. Bind a custom `selection` only when you need identifier-based or per-suite restore.
