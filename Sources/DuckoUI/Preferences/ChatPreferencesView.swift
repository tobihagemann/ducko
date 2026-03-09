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
            }
        }
        .formStyle(.grouped)
    }
}
