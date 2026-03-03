import SwiftUI

struct NotificationsPreferencesView: View {
    @State private var preferences = NotificationPreferences()

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Play Notification Sounds", isOn: Bindable(preferences).playNotificationSounds)
                Toggle("Do Not Disturb", isOn: Bindable(preferences).doNotDisturb)
            }
        }
        .formStyle(.grouped)
    }
}
