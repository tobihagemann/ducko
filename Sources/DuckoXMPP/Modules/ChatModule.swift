import os

/// Handles 1:1 `<message type="chat">` stanzas, including XEP-0308 corrections
/// and XEP-0461 replies.
public final class ChatModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    public func handleMessage(_ message: XMPPMessage) throws {
        guard message.messageType == .chat || message.messageType == .error else { return }
        guard let from = message.from else { return }

        let context = state.withLock { $0 }

        // Error messages
        if message.messageType == .error {
            let stanzaError = XMPPStanzaError.parse(from: message.element.child(named: "error"))
                ?? XMPPStanzaError(errorType: .cancel, condition: .undefinedCondition)
            context?.emitEvent(.messageError(messageID: message.id, from: from, error: stanzaError))
            return
        }

        // XEP-0308: Message correction
        if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
           let originalID = replace.attribute("id"),
           let newBody = message.body {
            context?.emitEvent(.messageCorrected(originalID: originalID, newBody: newBody, from: from))
            return
        }

        // Regular chat messages require a body
        guard message.body != nil else { return }
    }

    // MARK: - Sending

    /// Sends a chat message to the given JID.
    public func sendMessage(
        to recipient: JID,
        body: String,
        id: String? = nil,
        requestReceipt: Bool = false
    ) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, id: stanzaID)
        message.body = body
        if requestReceipt {
            let request = XMLElement(name: "request", namespace: XMPPNamespaces.receipts)
            message.element.addChild(request)
        }
        try await context.sendStanza(message)
    }

    /// Sends a message correction (XEP-0308) replacing a previously sent message.
    public func sendCorrection(
        to recipient: JID,
        body: String,
        replacingID: String,
        id: String? = nil
    ) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, id: stanzaID)
        message.body = body
        let replace = XMLElement(
            name: "replace",
            namespace: XMPPNamespaces.messageCorrect,
            attributes: ["id": replacingID]
        )
        message.element.addChild(replace)
        try await context.sendStanza(message)
    }

    /// Sends a reply (XEP-0461) to a specific message.
    public func sendReply(
        to recipient: JID,
        body: String,
        replyToID: String,
        replyToJID: JID,
        id: String? = nil
    ) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, id: stanzaID)
        message.body = body
        let reply = XMLElement(
            name: "reply",
            namespace: XMPPNamespaces.messageReply,
            attributes: ["to": replyToJID.description, "id": replyToID]
        )
        message.element.addChild(reply)
        try await context.sendStanza(message)
    }
}
