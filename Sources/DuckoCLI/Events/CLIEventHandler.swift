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
        case .messageReceived, .messageCarbonReceived, .messageCarbonSent,
             .roomMessageReceived, .roomInviteReceived,
             .jingleFileTransferReceived:
            if isInteractive, !(formatter is JSONFormatter) {
                print("\u{07}", terminator: "")
            }
        case let .chatStateChanged(from, state):
            guard isInteractive else { return }
            if let output = formatter.formatTypingIndicator(from: from, state: state) {
                print(output)
            }
            return
        case .jingleFileTransferProgress:
            guard isInteractive else { break }
        case .connected, .disconnected, .authenticationFailed,
             .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .archivedMessagesLoaded,
             .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageError,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged, .roomDestroyed,
             .jingleFileTransferCompleted, .jingleFileTransferFailed,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            break
        }
        guard let output = formatter.formatEvent(event, accountID: accountID) else { return }
        print(output)
    }
}
