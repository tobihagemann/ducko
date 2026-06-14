import CoreGraphics
import DuckoXMPP
import Foundation

@MainActor @Observable
public final class PresenceService {
    public var myPresence: PresenceStatus = .available
    public var myStatusMessage: String?
    private var contactPresencesByAccount: [UUID: [BareJID: PresenceStatus]] = [:]
    private var contactStatusMessagesByAccount: [UUID: [BareJID: String]] = [:]
    private var pendingRequestsByAccount: [UUID: [BareJID]] = [:]

    public var contactPresences: [BareJID: PresenceStatus] {
        contactPresencesByAccount.values.reduce(into: [:]) { result, dict in
            result.merge(dict) { _, new in new }
        }
    }

    public var contactStatusMessages: [BareJID: String] {
        contactStatusMessagesByAccount.values.reduce(into: [:]) { result, dict in
            result.merge(dict) { _, new in new }
        }
    }

    public func statusMessage(for jid: BareJID) -> String? {
        // Search per-account directly rather than materializing the merged dictionary
        // for a single-key read — this runs per contact row on every roster render.
        for messages in contactStatusMessagesByAccount.values {
            if let message = messages[jid] { return message }
        }
        return nil
    }

    /// Account-scoped presence lookup. Prefer this when the account is known: the merged
    /// `contactPresences` collapses every account's map last-account-wins on JID collision,
    /// so it resolves the wrong account when the same peer JID is on two.
    public func presence(for jid: BareJID, accountID: UUID) -> PresenceStatus? {
        contactPresencesByAccount[accountID]?[jid]
    }

    /// Account-scoped status-message lookup. Mirror of `presence(for:accountID:)`.
    public func statusMessage(for jid: BareJID, accountID: UUID) -> String? {
        contactStatusMessagesByAccount[accountID]?[jid]
    }

    public var pendingSubscriptionRequests: [BareJID] {
        pendingRequestsByAccount.values.flatMap(\.self)
    }

    public enum PresenceStatus: String, Sendable, CaseIterable {
        case available, away, xa, dnd, offline

        /// User-selectable presences in canonical `allCases` order, excluding
        /// `offline` (a disconnected state rather than a status picked alongside
        /// a custom message). Used by the menu-bar and custom-status menus; the
        /// Contacts header menu deliberately iterates the full `allCases` so it
        /// can also offer Offline (which disconnects).
        public static let selectableCases: [PresenceStatus] = allCases.filter { $0 != .offline }

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

    public enum PresenceServiceError: Error, LocalizedError {
        case notConnected(UUID)
        case invalidJID(String)

        public var errorDescription: String? {
            switch self {
            case let .notConnected(id): notConnectedDescription(id)
            case let .invalidJID(string): "Invalid JID: \(string)"
            }
        }
    }

    // MARK: - Public API

    /// Broadcasts on an already-connected account. Use `applyPresence` when reconnect may be needed.
    public func setPresence(_ status: PresenceStatus, message: String?, accountID: UUID) async {
        myPresence = status
        myStatusMessage = message
        await sendPresence(accountID: accountID)
    }

    /// Sends directed presence to a specific JID, using the user's current show/status.
    public func sendDirectedPresence(to jidString: String, accountID: UUID) async throws {
        guard let jid = JID.parse(jidString) else { throw PresenceServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw PresenceServiceError.notConnected(accountID) }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        try await presenceModule.sendDirectedPresence(to: jid, show: currentShow, status: myStatusMessage)
    }

    /// Updates `myPresence` / `myStatusMessage` synchronously (views see the change before any await). Reads
    /// `AccountService.connectionStates` rather than `myPresence` to decide reconnect — a `Picker` binding may have
    /// already mutated `myPresence`.
    public func applyPresence(
        _ status: PresenceStatus,
        message: String?,
        accountID: UUID,
        connect: @escaping (UUID) async throws -> Void,
        disconnect: @escaping (UUID) async -> Void
    ) async {
        if status == .offline {
            goOffline(accountID: accountID)
            await disconnect(accountID)
        } else {
            let isDisconnected = isAccountDisconnected(accountID: accountID)
            myPresence = status
            myStatusMessage = message
            if isDisconnected {
                try? await connect(accountID)
            }
            await sendPresence(accountID: accountID)
        }
    }

    /// Drops the pending subscription request from `jid` after the user has
    /// acted on it (approved, denied, or dismissed).
    public func removeSubscriptionRequest(_ jid: BareJID, accountID: UUID) {
        pendingRequestsByAccount[accountID]?.removeAll { $0 == jid }
    }

    /// Marks local presence offline only. Caller must invoke `AccountService.disconnect` so the server sees the unavailable stanza.
    public func goOffline(accountID _: UUID) {
        myPresence = .offline
        myStatusMessage = nil
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case .connected:
            await reapplyHeldPresenceAfterReconnect(accountID: accountID)
        case let .presenceUpdated(from, presence):
            handlePresenceUpdated(from: from, presence: presence, accountID: accountID)
        case let .presenceSubscriptionRequest(from):
            handleSubscriptionRequest(from: from, accountID: accountID)
        case .disconnected:
            contactPresencesByAccount.removeValue(forKey: accountID)
            contactStatusMessagesByAccount.removeValue(forKey: accountID)
            pendingRequestsByAccount.removeValue(forKey: accountID)
        case .presenceSubscriptionApproved, .presenceSubscriptionRevoked:
            break
        case .streamResumed, .authenticationFailed,
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
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    /// Re-broadcasts a non-default held presence after an automatic reconnect. `PresenceModule.handleConnect()`
    /// sends a blank available presence on every fresh connect, which would otherwise silently revert a chosen
    /// away/dnd/available-with-message back to plain available for peers mid-session. Skips plain
    /// default-available (already covered by `handleConnect`) and `.offline` (short-circuits in `sendPresence`).
    /// `.streamResumed` is intentionally not handled — a resumed session skips `handleConnect()`, so presence is
    /// never reset.
    private func reapplyHeldPresenceAfterReconnect(accountID: UUID) async {
        guard shouldReapplyHeldPresence else { return }
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        // `.connected` is yielded before `PresenceModule.handleConnect()` sends its blank-available stanza, so
        // gate on the initial presence before re-broadcasting or it would just be overwritten.
        await client.awaitInitialPresenceSent()
        // Across the await the original client can disconnect and a replacement enter `.connected`; re-verify the
        // same instance and re-check the guard so a stale reapply can't clobber the new client's presence.
        guard accountService?.connectedClient(for: accountID) === client, shouldReapplyHeldPresence else { return }
        await sendPresence(accountID: accountID)
    }

    private var shouldReapplyHeldPresence: Bool {
        myPresence != .offline && (myPresence != .available || myStatusMessage != nil)
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

    private func isAccountDisconnected(accountID: UUID) -> Bool {
        Self.isDisconnected(state: accountService?.connectionStates[accountID])
    }

    /// Classifies a connection state for reconnect. `nil` (no service wired) and `.error` both count as disconnected
    /// so test harnesses without `AccountService` and error-state retries exercise the connect path.
    nonisolated static func isDisconnected(state: AccountService.ConnectionState?) -> Bool {
        guard let state else { return true }
        return switch state {
        case .disconnected, .error: true
        case .connecting, .connected: false
        }
    }

    private func handlePresenceUpdated(from: JID, presence: XMPPPresence, accountID: UUID) {
        let bareJID = from.bareJID
        let status = mapPresence(presence)
        if status == .offline {
            contactPresencesByAccount[accountID, default: [:]].removeValue(forKey: bareJID)
        } else {
            contactPresencesByAccount[accountID, default: [:]][bareJID] = status
        }

        // Stores the status from the most recently applied presence; multi-resource
        // priority handling is out of scope for v1. Clearing when the trimmed text is
        // empty (or the peer went offline) keeps a stale custom status from sticking
        // after the peer returns to plain available.
        let trimmedStatus = presence.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == .offline || (trimmedStatus?.isEmpty ?? true) {
            contactStatusMessagesByAccount[accountID, default: [:]].removeValue(forKey: bareJID)
        } else {
            contactStatusMessagesByAccount[accountID, default: [:]][bareJID] = trimmedStatus
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
        guard let client = accountService?.connectedClient(for: accountID) else { return }
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
