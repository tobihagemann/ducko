import CoreGraphics
import DuckoXMPP
import Foundation

@MainActor @Observable
public final class PresenceService {
    public var myPresence: PresenceStatus = .available
    public var myStatusMessage: String?
    private var contactPresencesByAccount: [UUID: [BareJID: PresenceStatus]] = [:]
    private var pendingRequestsByAccount: [UUID: [BareJID]] = [:]

    public var contactPresences: [BareJID: PresenceStatus] {
        contactPresencesByAccount.values.reduce(into: [:]) { result, dict in
            result.merge(dict) { _, new in new }
        }
    }

    public var pendingSubscriptionRequests: [BareJID] {
        pendingRequestsByAccount.values.flatMap(\.self)
    }

    public enum PresenceStatus: String, Sendable {
        case available, away, xa, dnd, offline

        public var displayName: String {
            switch self {
            case .available: "Available"
            case .away: "Away"
            case .xa: "Extended Away"
            case .dnd: "Do Not Disturb"
            case .offline: "Offline"
            }
        }
    }

    private weak var accountService: AccountService?
    private var idleMonitorTask: Task<Void, Never>?
    private var autoAwayActive: Bool = false
    private var previousPresence: PresenceStatus?
    private let idleTimeSource: any IdleTimeSource

    public init(idleTimeSource: any IdleTimeSource = SystemIdleTimeSource()) {
        self.idleTimeSource = idleTimeSource
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    // MARK: - Public API

    public func setPresence(_ status: PresenceStatus, message: String?, accountID: UUID) async {
        myPresence = status
        myStatusMessage = message
        await sendPresence(accountID: accountID)
    }

    /// Sends directed presence to a specific JID, using the user's current show/status.
    public func sendDirectedPresence(to jidString: String, accountID: UUID) async throws {
        guard let jid = JID.parse(jidString) else { return }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        try await presenceModule.sendDirectedPresence(to: jid, show: currentShow, status: myStatusMessage)
    }

    public func applyPresence(
        _ status: PresenceStatus,
        message: String?,
        accountID: UUID,
        connect: @escaping (UUID) async throws -> Void,
        disconnect: @escaping (UUID) async -> Void
    ) async {
        let wasOffline = myPresence == .offline
        if status == .offline {
            goOffline(accountID: accountID)
            await disconnect(accountID)
        } else {
            if wasOffline {
                try? await connect(accountID)
            }
            await setPresence(status, message: message, accountID: accountID)
        }
    }

    public func removeSubscriptionRequest(_ jid: BareJID, accountID: UUID) {
        pendingRequestsByAccount[accountID]?.removeAll { $0 == jid }
    }

    public func goOffline(accountID _: UUID) {
        myPresence = .offline
        myStatusMessage = nil
        // Unavailable presence is sent by the server on disconnect.
        // The caller should use AccountService.disconnect to fully go offline.
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .presenceUpdated(from, presence):
            handlePresenceUpdated(from: from, presence: presence, accountID: accountID)
        case let .presenceSubscriptionRequest(from):
            handleSubscriptionRequest(from: from, accountID: accountID)
        case .disconnected:
            contactPresencesByAccount.removeValue(forKey: accountID)
            pendingRequestsByAccount.removeValue(forKey: accountID)
        case .presenceSubscriptionApproved, .presenceSubscriptionRevoked:
            break
        case .connected, .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleFileRequestReceived, .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted,
             .jingleContentRejected, .jingleContentRemoved,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    // MARK: - Idle Monitoring

    /// Opt-in idle monitoring (GUI calls this, CLI doesn't).
    public func startIdleMonitoring(accountID: UUID, timeout: TimeInterval = 300) {
        stopIdleMonitoring()

        idleMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }

                let idleTime = idleTimeSource.secondsSinceLastUserInput()

                if idleTime >= timeout, !autoAwayActive {
                    previousPresence = myPresence
                    autoAwayActive = true
                    myPresence = .away
                    await sendPresence(accountID: accountID)
                } else if idleTime < timeout, autoAwayActive {
                    autoAwayActive = false
                    myPresence = previousPresence ?? .available
                    previousPresence = nil
                    await sendPresence(accountID: accountID)
                }
            }
        }
    }

    public func stopIdleMonitoring() {
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
    }

    // MARK: - Private

    private func handlePresenceUpdated(from: JID, presence: XMPPPresence, accountID: UUID) {
        let bareJID = from.bareJID
        let status = mapPresence(presence)
        if status == .offline {
            contactPresencesByAccount[accountID, default: [:]].removeValue(forKey: bareJID)
        } else {
            contactPresencesByAccount[accountID, default: [:]][bareJID] = status
        }
    }

    private func handleSubscriptionRequest(from: BareJID, accountID: UUID) {
        let requests = pendingRequestsByAccount[accountID] ?? []
        if !requests.contains(from) {
            pendingRequestsByAccount[accountID, default: []].append(from)
        }
    }

    private func mapPresence(_ presence: XMPPPresence) -> PresenceStatus {
        if presence.presenceType == .unavailable {
            return .offline
        }
        guard let show = presence.show else {
            return .available
        }
        return switch show {
        case .chat: .available
        case .away: .away
        case .xa: .xa
        case .dnd: .dnd
        }
    }

    public var currentShow: XMPPPresence.Show? {
        switch myPresence {
        case .available, .offline: nil
        case .away: .away
        case .xa: .xa
        case .dnd: .dnd
        }
    }

    private func sendPresence(accountID: UUID) async {
        guard myPresence != .offline else { return }
        guard let client = accountService?.client(for: accountID) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        try? await presenceModule.broadcastPresence(show: currentShow, status: myStatusMessage)
    }
}

// MARK: - Idle Time Source

public protocol IdleTimeSource: Sendable {
    func secondsSinceLastUserInput() -> TimeInterval
}

public struct SystemIdleTimeSource: IdleTimeSource {
    public init() {}

    public func secondsSinceLastUserInput() -> TimeInterval {
        // Check both mouse and keyboard activity; return the shorter idle time.
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keyboard = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return min(mouse, keyboard)
    }
}
