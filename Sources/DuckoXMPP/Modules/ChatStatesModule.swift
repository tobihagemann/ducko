import os

/// Implements XEP-0085 Chat State Notifications — sends and receives
/// typing indicators and other chat state changes.
public final class ChatStatesModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    public var features: [String] {
        [XMPPNamespaces.chatStates]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        guard let from = message.from?.bareJID else { return }

        guard let chatState = ChatState.allCases.first(where: {
            message.element.child(named: $0.rawValue, namespace: XMPPNamespaces.chatStates) != nil
        }) else { return }

        let context = state.withLock { $0 }
        context?.emitEvent(.chatStateChanged(from: from, state: chatState))
    }

    // MARK: - Sending

    /// Sends a standalone chat state notification to the given JID.
    public func sendChatState(_ chatState: ChatState, to recipient: JID) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        var message = XMPPMessage(type: .chat, to: recipient, id: context.generateID())
        let child = XMLElement(name: chatState.rawValue, namespace: XMPPNamespaces.chatStates)
        message.element.addChild(child)
        try await context.sendStanza(message)
    }
}
