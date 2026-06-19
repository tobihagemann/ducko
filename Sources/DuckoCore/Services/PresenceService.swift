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

    /// Sparse per-account pins layered over the global `myPresence`/`myStatusMessage`. An account with
    /// an entry broadcasts its own status; any global change wipes the whole map (Adium's "reset everyone").
    private var presenceOverridesByAccount: [UUID: OwnPresenceOverride] = [:]

    private struct OwnPresenceOverride {
        var status: PresenceStatus
        var message: String?
    }

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
        // A user-initiated disconnect cancels the account's event task before the `.disconnected(.requested)`
        // event can reach `handleEvent`, so clear the per-account override here instead — a stream-blip
        // reconnect goes through `handleDisconnect` and never fires this, preserving the pinned override.
        service.onRequestedDisconnect = { [weak self] accountID in
            self?.presenceOverridesByAccount.removeValue(forKey: accountID)
        }
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
        cancelAutoAway()
        myPresence = status
        myStatusMessage = message
        await sendPresence(accountID: accountID)
    }

    /// Sends directed presence to a specific JID, using the account's effective show/status so a directed
    /// presence from an overridden account matches its broadcast status.
    public func sendDirectedPresence(to jidString: String, accountID: UUID) async throws {
        guard let jid = JID.parse(jidString) else { throw PresenceServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw PresenceServiceError.notConnected(accountID) }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        try await presenceModule.sendDirectedPresence(to: jid, show: effectiveShow(for: accountID), status: effectivePresence(for: accountID).message)
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
            cancelAutoAway()
            let isDisconnected = isAccountDisconnected(accountID: accountID)
            myPresence = status
            myStatusMessage = message
            if isDisconnected {
                try? await connect(accountID)
            }
            await sendPresence(accountID: accountID)
        }
    }

    /// Sets the global status and broadcasts it to every online account, clearing any per-account overrides
    /// first (Adium's "reset everyone to the same"). `identityAccountID` carries the UI's resolved header
    /// identity so an Available-from-fully-offline action isn't a silent no-op when no `connectOnLaunch`
    /// account exists. Reads `AccountService.connectionStates` directly so the offline teardown also reaches
    /// `.connecting`/reconnecting accounts.
    public func applyGlobalPresence(
        _ status: PresenceStatus,
        message: String?,
        identityAccountID: UUID?,
        connect: @escaping (UUID) async throws -> Void,
        disconnect: @escaping (UUID) async -> Void
    ) async {
        cancelAutoAway()
        presenceOverridesByAccount.removeAll()
        myPresence = status
        myStatusMessage = status == .offline ? nil : message

        if status == .offline {
            // Tear down every account that isn't already disconnected — connected, connecting, and
            // reconnecting (`.error`) — so an in-flight connect can't finish and emit available after offline.
            for account in accountService?.accounts ?? [] {
                switch accountService?.connectionStates[account.id] {
                case .connected, .connecting, .error:
                    await disconnect(account.id)
                case .disconnected, .none:
                    break
                }
            }
        } else {
            // Going online from fully-offline mirrors launch: reconnect the normal online set
            // (`connectOnLaunch` accounts), falling back to the identity account so the action isn't a no-op.
            // Skip accounts already connecting (`isAccountDisconnected` is false for `.connecting`/`.connected`)
            // so an in-flight connect isn't torn down and restarted.
            if let accountService, !accountService.hasAnyConnectedAccount {
                let onlineSet = accountService.accounts.filter { $0.isEnabled && $0.connectOnLaunch }
                if onlineSet.isEmpty {
                    if let identityAccountID, isAccountDisconnected(accountID: identityAccountID) {
                        try? await connect(identityAccountID)
                    }
                } else {
                    for account in onlineSet where isAccountDisconnected(accountID: account.id) {
                        try? await connect(account.id)
                    }
                }
            }
            await broadcastPresenceToConnectedAccounts()
        }
    }

    /// Pins `accountID` to its own status, layered over the global value. Offline is not modeled as an override:
    /// it disconnects the account (the submenu derives Offline from connection state), and any prior override is
    /// dropped so a later reconnect doesn't resurface it.
    public func applyAccountPresence(
        _ status: PresenceStatus,
        message: String?,
        accountID: UUID,
        connect: @escaping (UUID) async throws -> Void,
        disconnect: @escaping (UUID) async -> Void
    ) async {
        if status == .offline {
            presenceOverridesByAccount.removeValue(forKey: accountID)
            await disconnect(accountID)
        } else {
            presenceOverridesByAccount[accountID] = OwnPresenceOverride(status: status, message: message)
            if isAccountDisconnected(accountID: accountID) {
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
        cancelAutoAway()
        myPresence = .offline
        myStatusMessage = nil
    }

    /// Cancels a pending auto-away restore. Any deliberate presence change (offline, away, a custom status)
    /// supersedes the held auto-away state, so a later idle-return must not flip back to it and broadcast
    /// that stale presence to the still-connected accounts.
    private func cancelAutoAway() {
        autoAwayActive = false
        previousPresence = nil
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
        case let .disconnected(reason):
            contactPresencesByAccount.removeValue(forKey: accountID)
            contactStatusMessagesByAccount.removeValue(forKey: accountID)
            pendingRequestsByAccount.removeValue(forKey: accountID)
            // Drop a per-account override only on intentional teardown; preserve it across a stream
            // blip + auto-reconnect so a pinned status isn't silently lost.
            if case .requested = reason {
                presenceOverridesByAccount.removeValue(forKey: accountID)
            }
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
        guard shouldReapplyHeldPresence(accountID: accountID) else { return }
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        // `.connected` is yielded before `PresenceModule.handleConnect()` sends its blank-available stanza, so
        // gate on the initial presence before re-broadcasting or it would just be overwritten.
        await client.awaitInitialPresenceSent()
        // Across the await the original client can disconnect and a replacement enter `.connected`; re-verify the
        // same instance and re-check the guard so a stale reapply can't clobber the new client's presence.
        guard accountService?.connectedClient(for: accountID) === client, shouldReapplyHeldPresence(accountID: accountID) else { return }
        await sendPresence(accountID: accountID)
    }

    /// Reads the account's *effective* presence so an account whose global is plain available but which carries a
    /// non-offline override still re-broadcasts (and replaces the blank-available stanza) after reconnect.
    private func shouldReapplyHeldPresence(accountID: UUID) -> Bool {
        let effective = effectivePresence(for: accountID)
        return effective.status != .offline && (effective.status != .available || effective.message != nil)
    }

    // MARK: - Idle Monitoring

    /// Opt-in idle monitoring (GUI calls this, CLI doesn't). A single global
    /// monitor that, on each transition, broadcasts to every connected account.
    public func startIdleMonitoring(timeout: TimeInterval = 300) {
        stopIdleMonitoring()

        idleMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await applyIdleTransition(idleTime: idleTimeSource.secondsSinceLastUserInput(), timeout: timeout)
            }
        }
    }

    public func stopIdleMonitoring() {
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
    }

    /// Applies one idle poll's state transition. Activates auto-away once idle past `timeout` — but never for
    /// a user who is deliberately `.offline` — and restores the held presence on the return to activity. Both
    /// transitions broadcast to every connected account.
    func applyIdleTransition(idleTime: TimeInterval, timeout: TimeInterval) async {
        if idleTime >= timeout, !autoAwayActive, myPresence != .offline {
            previousPresence = myPresence
            autoAwayActive = true
            myPresence = .away
            await broadcastPresenceToConnectedAccounts()
        } else if idleTime < timeout, autoAwayActive {
            autoAwayActive = false
            myPresence = previousPresence ?? .available
            previousPresence = nil
            await broadcastPresenceToConnectedAccounts()
        }
    }

    /// Broadcasts the current `myPresence` to every connected account, so idle
    /// auto-away/return moves all accounts together. Reuses the per-account
    /// `sendPresence`, which short-circuits on `.offline` or a missing client.
    func broadcastPresenceToConnectedAccounts() async {
        guard let accountService else { return }
        for account in accountService.accounts where accountService.connectedClient(for: account.id) != nil {
            await sendPresence(accountID: account.id)
        }
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
        Self.show(for: myPresence)
    }

    /// The presence pinned for `accountID`, falling back to the global values when no override is set.
    /// Every outbound presence path reads this so an overridden account never reverts to global; the Contacts
    /// header also reads it so the dot/label reflect the displayed identity account's actual status.
    public func effectivePresence(for accountID: UUID) -> (status: PresenceStatus, message: String?) {
        if let override = presenceOverridesByAccount[accountID] {
            return (override.status, override.message)
        }
        return (myPresence, myStatusMessage)
    }

    /// The effective `Show` for an account, mirroring `currentShow` over `effectivePresence(for:)`.
    func effectiveShow(for accountID: UUID) -> XMPPPresence.Show? {
        Self.show(for: effectivePresence(for: accountID).status)
    }

    /// The effective status for an account, surfaced to the UI's per-account submenu.
    public func effectiveStatus(for accountID: UUID) -> PresenceStatus {
        effectivePresence(for: accountID).status
    }

    private static func show(for status: PresenceStatus) -> XMPPPresence.Show? {
        switch status {
        case .available, .offline: nil
        case .away: .away
        case .xa: .xa
        case .dnd: .dnd
        }
    }

    /// Re-broadcasts an account's effective presence. `AvatarService` routes its re-broadcasts through this so
    /// an avatar/vCard/MUC update never clobbers an overridden account back to the global status.
    func resendEffectivePresence(accountID: UUID) async {
        await sendPresence(accountID: accountID)
    }

    private func sendPresence(accountID: UUID) async {
        // Global offline is a hard stop: never broadcast presence while the user is offline, even if an
        // account still carries a non-offline override.
        guard myPresence != .offline else { return }
        let effective = effectivePresence(for: accountID)
        guard effective.status != .offline else { return }
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        try? await presenceModule.broadcastPresence(show: effectiveShow(for: accountID), status: effective.message)
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
