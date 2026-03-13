import DuckoCore
import SwiftUI

struct ChatPreferencesView: View {
    @State private var preferences = ChatPreferences.shared

    var body: some View {
        Form {
            Section("Chat") {
                Toggle("Send typing indicators", isOn: Bindable(preferences).enableChatStates)
                    .accessibilityIdentifier("chatStatesToggle")
                    .help("Let others know when you are typing. Also attaches chat state to outgoing messages.")
                Toggle("Send read receipts", isOn: Bindable(preferences).enableDisplayedMarkers)
                    .accessibilityIdentifier("displayedMarkersToggle")
                    .help("Send displayed markers to let others know you have read their messages.")
            }
        }
        .formStyle(.grouped)
    }
}
