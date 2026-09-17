import SwiftUI

struct GeneralPreferencesView: View {
    @Environment(GeneralPreferences.self) private var preferences

    var body: some View {
        Form {
            Section("Application") {
                Toggle("Show Ducko in Menu Bar", isOn: Bindable(preferences).showInMenuBar)
                    .accessibilityIdentifier("showInMenuBarToggle")

                Toggle("Launch at Login", isOn: Bindable(preferences).launchAtLogin)
                    .disabled(!preferences.isLaunchAtLoginAvailable)
                    .help(preferences.isLaunchAtLoginAvailable ? "" : "Only available in release builds")
            }
        }
        .formStyle(.grouped)
    }
}
