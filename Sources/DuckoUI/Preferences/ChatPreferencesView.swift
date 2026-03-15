import DuckoCore
import SwiftUI

struct ChatPreferencesView: View {
    @State private var preferences = ChatPreferences.shared
    @State private var omemoPreferences = OMEMOPreferences.shared

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

            Section("Encryption") {
                Toggle("Enable encryption by default", isOn: Bindable(omemoPreferences).encryptByDefault)
                    .accessibilityIdentifier("encryptByDefaultToggle")
                    .help("New conversations will have OMEMO encryption enabled by default.")
                Toggle("Trust On First Use (TOFU)", isOn: Bindable(omemoPreferences).trustOnFirstUse)
                    .accessibilityIdentifier("tofuToggle")
                    .help("Automatically trust new devices on first contact. Disable for manual trust decisions only.")
            }
        }
        .formStyle(.grouped)
    }
}
