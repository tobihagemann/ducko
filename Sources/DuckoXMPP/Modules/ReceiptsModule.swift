import os

private let log = Logger(subsystem: "com.ducko.xmpp", category: "receipts")

/// Implements XEP-0184 Message Delivery Receipts and XEP-0333 Chat Markers —
/// auto-replies to receipt requests and emits events for incoming receipts/markers.
public final class ReceiptsModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    public var features: [String] {
        [XMPPNamespaces.receipts, XMPPNamespaces.chatMarkers]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        guard let from = message.from else { return }
        let context = state.withLock { $0 }

        // XEP-0184: Incoming receipt request — auto-reply for chat messages with body
        if message.element.child(named: "request", namespace: XMPPNamespaces.receipts) != nil,
           message.messageType == .chat,
           message.body != nil,
           let stanzaID = message.id {
            sendReceiptReply(to: from, messageID: stanzaID)
        }

        // XEP-0184: Incoming delivery receipt
        if let received = message.element.child(named: "received", namespace: XMPPNamespaces.receipts),
           let messageID = received.attribute("id") {
            context?.emitEvent(.deliveryReceiptReceived(messageID: messageID, from: from))
        }

        // XEP-0333: Incoming chat markers
        for markerType in ChatMarkerType.allCases {
            if let marker = message.element.child(named: markerType.rawValue, namespace: XMPPNamespaces.chatMarkers),
               let messageID = marker.attribute("id") {
                context?.emitEvent(.chatMarkerReceived(messageID: messageID, type: markerType, from: from))
                break
            }
        }
    }

    // MARK: - Sending

    /// Sends a `displayed` chat marker to indicate the message was read.
    public func sendDisplayedMarker(to recipient: JID, messageID: String) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        var message = XMPPMessage(type: .chat, to: recipient, id: context.generateID())
        let marker = XMLElement(
            name: "displayed",
            namespace: XMPPNamespaces.chatMarkers,
            attributes: ["id": messageID]
        )
        message.element.addChild(marker)
        try await context.sendStanza(message)
    }

    // MARK: - Private

    private func sendReceiptReply(to recipient: JID, messageID: String) {
        let context = state.withLock { $0 }
        guard let context else { return }
        Task {
            var reply = XMPPMessage(type: .chat, to: recipient, id: context.generateID())
            let received = XMLElement(
                name: "received",
                namespace: XMPPNamespaces.receipts,
                attributes: ["id": messageID]
            )
            reply.element.addChild(received)
            do {
                try await context.sendStanza(reply)
            } catch {
                log.warning("Failed to send delivery receipt: \(error)")
            }
        }
    }
}
