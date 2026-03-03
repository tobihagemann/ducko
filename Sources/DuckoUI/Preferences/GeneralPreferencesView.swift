import SwiftUI

struct GeneralPreferencesView: View {
    @State private var preferences = GeneralPreferences()

    var body: some View {
        Form {
            Section("Application") {
                Toggle("Show Ducko in Dock", isOn: Bindable(preferences).showInDock)

                Toggle("Launch at Login", isOn: Bindable(preferences).launchAtLogin)
                    .disabled(!preferences.isLaunchAtLoginAvailable)
                    .help(preferences.isLaunchAtLoginAvailable ? "" : "Only available in release builds")
            }
        }
        .formStyle(.grouped)
    }
}
