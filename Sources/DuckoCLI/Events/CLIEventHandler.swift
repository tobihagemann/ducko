import DuckoXMPP
import Foundation

actor CLIEventHandler {
    private let formatter: any CLIFormatter
    private let isInteractive: Bool

    init(formatter: any CLIFormatter, isInteractive: Bool = false) {
        self.formatter = formatter
        self.isInteractive = isInteractive
    }

    func handleEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .messageReceived(message):
            if shouldSkipRawMessage(message) { return }
            ringBell()
        case .messageCarbonReceived, .messageCarbonSent,
             .roomMessageReceived, .mucPrivateMessageReceived, .roomInviteReceived,
             .jingleFileTransferReceived, .jingleFileRequestReceived:
            ringBell()
        case let .chatStateChanged(from, state):
            handleChatState(from: from, state: state)
            return
        case .jingleFileTransferProgress,
             .omemoDeviceListReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            guard isInteractive else { break }
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .archivedMessagesLoaded,
             .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferCompleted, .jingleFileTransferFailed,
             .jingleChecksumReceived, .jingleChecksumMismatch,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoEncryptedMessageReceived:
            break
        }
        guard let output = formatter.formatEvent(event, accountID: accountID) else { return }
        print(output)
    }

    private func handleChatState(from: BareJID, state: ChatState) {
        guard isInteractive else { return }
        if let output = formatter.formatTypingIndicator(from: from, state: state) {
            print(output)
        }
    }

    private func shouldSkipRawMessage(_ message: XMPPMessage) -> Bool {
        message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) != nil
            || message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect) != nil
            || message.element.child(named: "encryption", namespace: XMPPNamespaces.eme) != nil
    }

    private func ringBell() {
        if isInteractive, !(formatter is JSONFormatter) {
            print("\u{07}", terminator: "")
        }
    }
}
