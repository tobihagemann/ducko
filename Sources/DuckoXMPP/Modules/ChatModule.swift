import os

/// Handles 1:1 `<message type="chat">` stanzas.
final class ChatModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    func handleMessage(_ message: XMPPMessage) throws {
        // Filtering only; the client already emits .messageReceived for all messages.
        guard message.messageType == .chat, message.body != nil else { return }
    }

    // MARK: - Sending

    /// Sends a chat message to the given JID.
    func sendMessage(to recipient: JID, body: String, id: String? = nil) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, id: stanzaID)
        message.body = body
        try await context.sendStanza(message)
    }
}
