import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.carbons")

/// Implements XEP-0280 Message Carbons — receives copies of messages
/// sent or received by other resources on the same account.
public final class CarbonsModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        var inlineEnabled: Bool = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.carbons]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    /// Marks carbons as already enabled via Bind 2 inline negotiation.
    public func markInlineEnabled() {
        state.withLock { $0.inlineEnabled = true }
    }

    public func handleConnect() async throws {
        // Skip if carbons were already enabled inline via Bind 2
        let alreadyEnabled = state.withLock { $0.inlineEnabled }
        if alreadyEnabled {
            log.info("Message Carbons already enabled via inline negotiation")
            return
        }

        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        let enable = XMLElement(name: "enable", namespace: XMPPNamespaces.carbons)
        iq.element.addChild(enable)

        do {
            _ = try await context.sendIQ(iq)
            log.info("Message Carbons enabled")
        } catch {
            log.warning("Failed to enable Message Carbons: \(error)")
        }
    }

    public func handleDisconnect() async {
        state.withLock { $0.inlineEnabled = false }
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        // Early-return for non-carbon messages
        let received = message.element.child(named: "received", namespace: XMPPNamespaces.carbons)
        let sent = message.element.child(named: "sent", namespace: XMPPNamespaces.carbons)
        guard received != nil || sent != nil else { return }

        let context = state.withLock { $0.context }
        guard let context else { return }

        // Security: verify the carbon comes from own bare JID
        guard let from = message.from,
              let connectedJID = context.connectedJID(),
              from.bareJID == connectedJID.bareJID else {
            log.warning("Rejected carbon with missing or foreign from: \(message.from?.description ?? "nil")")
            return
        }

        if let received,
           let forwardedElement = received.child(named: "forwarded", namespace: XMPPNamespaces.forward),
           let forwarded = ForwardedMessage.parse(forwardedElement) {
            context.emitEvent(.messageCarbonReceived(forwarded))
        } else if let sent,
                  let forwardedElement = sent.child(named: "forwarded", namespace: XMPPNamespaces.forward),
                  let forwarded = ForwardedMessage.parse(forwardedElement) {
            context.emitEvent(.messageCarbonSent(forwarded))
        }
    }
}
