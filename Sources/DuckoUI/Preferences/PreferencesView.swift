import SwiftUI

/// Panes share one width so the centered toolbar stays put, and each pane sets
/// its own height, which the `Settings` window resizes to. The `Settings` scene
/// restores the last-viewed tab itself.
public struct PreferencesView: View {
    public init() {}

    public var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralPreferencesView()
            }

            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountsPreferencesView()
            }

            Tab("Chat", systemImage: "bubble.left.and.bubble.right") {
                ChatPreferencesView()
            }

            Tab("Status", systemImage: "circle.lefthalf.filled") {
                StatusPreferencesView()
            }

            Tab("Appearance", systemImage: "paintbrush") {
                AppearancePreferencesView()
            }

            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                AdvancedPreferencesView()
            }
        }
        .frame(width: 600)
        .accessibilityIdentifier("preferences-window")
    }
}
