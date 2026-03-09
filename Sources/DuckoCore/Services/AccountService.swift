import DuckoXMPP
import Foundation

@MainActor @Observable
public final class AccountService {
    // MARK: - Published State

    public private(set) var accounts: [Account] = []
    public private(set) var connectionStates: [UUID: ConnectionState] = [:]

    // MARK: - Internal

    private let store: any PersistenceStore
    private let credentialStore: any CredentialStore
    private var clients: [UUID: XMPPClient] = [:]
    private var smModules: [UUID: StreamManagementModule] = [:]
    private var smResumeStates: [UUID: SMResumeState] = [:]
    private var passwords: [UUID: String] = [:]
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    var onEvent: ((XMPPEvent, UUID) -> Void)?

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected(FullJID)
        case error(String)
    }

    public enum AccountServiceError: Error, LocalizedError {
        case invalidJID(String)
        case noStoredPassword(String)

        public var errorDescription: String? {
            switch self {
            case let .invalidJID(string): "Invalid JID: \(string)"
            case let .noStoredPassword(jid): "No stored password for \(jid)"
            }
        }
    }

    public init(store: any PersistenceStore, credentialStore: any CredentialStore) {
        self.store = store
        self.credentialStore = credentialStore
    }

    // MARK: - Lifecycle

    public func loadAccounts() async throws {
        accounts = try await store.fetchAccounts()
        for account in accounts where connectionStates[account.id] == nil {
            connectionStates[account.id] = .disconnected
        }
    }

    public func connect(accountID: UUID, password: String) async throws {
        passwords[accountID] = password
        cancelReconnect(for: accountID, resetAttempts: true)
        try await performConnect(accountID: accountID)
    }

    public func connect(accountID: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AccountServiceError.noStoredPassword(accountID.uuidString)
        }
        let jid = account.jid.description
        guard let password = credentialStore.loadPassword(for: jid) else {
            throw AccountServiceError.noStoredPassword(jid)
        }
        try await connect(accountID: accountID, password: password)
    }

    public func savePassword(accountID: UUID) async {
        if accounts.first(where: { $0.id == accountID }) == nil {
            try? await loadAccounts()
        }
        guard let account = accounts.first(where: { $0.id == accountID }),
              let password = passwords[accountID]
        else { return }
        credentialStore.savePassword(password, for: account.jid.description)
    }

    public func deletePassword(accountID: UUID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        credentialStore.deletePassword(for: account.jid.description)
    }

    public func disconnect(accountID: UUID) async {
        cancelReconnect(for: accountID, resetAttempts: true)
        passwords[accountID] = nil
        smResumeStates[accountID] = nil
        smModules[accountID] = nil
        eventTasks[accountID]?.cancel()
        eventTasks[accountID] = nil

        if let client = clients.removeValue(forKey: accountID) {
            await client.disconnect()
        }
        connectionStates[accountID] = .disconnected
    }

    public func createAccount(
        jidString: String,
        displayName: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        resource: String? = nil,
        connectOnLaunch: Bool = false
    ) async throws -> UUID {
        guard let jid = BareJID.parse(jidString) else {
            throw AccountServiceError.invalidJID(jidString)
        }
        let account = Account(
            id: UUID(),
            jid: jid,
            displayName: displayName,
            isEnabled: true,
            connectOnLaunch: connectOnLaunch,
            host: host,
            port: port,
            resource: resource,
            createdAt: Date()
        )
        try await store.saveAccount(account)
        return account.id
    }

    public func updateAccount(_ account: Account) async throws {
        try await store.saveAccount(account)
        if !account.isEnabled {
            await disconnect(accountID: account.id)
        }
        try await loadAccounts()
    }

    public func connectEnabledAccounts() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts where account.isEnabled && account.connectOnLaunch {
                let state = connectionStates[account.id]
                switch state {
                case .connected, .connecting:
                    continue
                case .disconnected, .error, .none:
                    break
                }
                group.addTask { [weak self] in
                    try? await self?.connect(accountID: account.id)
                }
            }
        }
    }

    public func deleteAccount(_ id: UUID) async throws {
        await disconnect(accountID: id)
        try await store.deleteAccount(id)
        deletePassword(accountID: id)
        try await loadAccounts()
    }

    // MARK: - Client Access

    func client(for accountID: UUID) -> XMPPClient? {
        clients[accountID]
    }

    /// Returns TLS connection info for a connected account.
    public func tlsInfo(for accountID: UUID) -> TLSInfo? {
        clients[accountID]?.tlsInfo
    }

    // MARK: - Private: Connection

    private func performConnect(accountID: UUID) async throws {
        let account: Account
        if let existing = accounts.first(where: { $0.id == accountID }) {
            account = existing
        } else {
            let all = try await store.fetchAccounts()
            guard let fetched = all.first(where: { $0.id == accountID }) else { return }
            account = fetched
        }

        connectionStates[accountID] = .connecting

        let previousSMState = smResumeStates.removeValue(forKey: accountID)
        let (client, sm) = await buildClient(account: account, previousSMState: previousSMState)
        clients[accountID] = client
        smModules[accountID] = sm

        startEventConsumption(for: accountID, client: client)

        do {
            if let location = previousSMState?.location {
                let parts = location.split(separator: ":")
                let host = String(parts[0])
                let port = parts.count > 1 ? UInt16(parts[1]) ?? 5222 : 5222
                try await client.connect(host: host, port: port)
            } else if let host = account.host, let port = account.port {
                try await client.connect(host: host, port: UInt16(port))
            } else {
                try await client.connect()
            }
        } catch {
            // Restore SM state so the next retry can attempt resumption
            if let smState = sm.resumeState {
                smResumeStates[accountID] = smState
            }
            connectionStates[accountID] = .error(error.localizedDescription)
            throw error
        }
    }

    private func buildClient(
        account: Account, previousSMState: SMResumeState?
    ) async -> (XMPPClient, StreamManagementModule) {
        var builder = XMPPClientBuilder(
            domain: account.jid.domainPart,
            username: account.jid.localPart ?? "",
            password: passwords[account.id] ?? ""
        )
        builder.withRequireTLS(account.requireTLS)
        let rosterModule = RosterModule()
        let rosterVersion = account.rosterVersion
        rosterModule.setRosterVersionProvider { rosterVersion }
        builder.withModule(ChatModule())
        builder.withModule(rosterModule)
        builder.withModule(PresenceModule())
        builder.withModule(ServiceDiscoveryModule())
        builder.withModule(CapsModule())
        builder.withModule(VCardModule())
        builder.withModule(ReceiptsModule())
        builder.withModule(ChatStatesModule())
        builder.withModule(CarbonsModule())
        builder.withModule(MAMModule())
        builder.withModule(PingModule())
        builder.withModule(MUCModule())
        builder.withModule(HTTPUploadModule())
        builder.withModule(JingleModule())
        builder.withModule(PEPModule())
        builder.withModule(BlockingModule())
        let sm = StreamManagementModule(previousState: previousSMState)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        return await (builder.build(), sm)
    }

    // MARK: - Private: Event Consumption

    private func startEventConsumption(for accountID: UUID, client: XMPPClient) {
        eventTasks[accountID]?.cancel()

        eventTasks[accountID] = Task { [weak self] in
            for await event in client.events {
                guard let self, !Task.isCancelled else { return }
                handleEvent(event, accountID: accountID)
            }
        }
    }

    private func handleEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .connected(jid), let .streamResumed(jid):
            connectionStates[accountID] = .connected(jid)
            reconnectAttempts[accountID] = 0
        case let .disconnected(reason):
            switch reason {
            case .requested:
                smResumeStates[accountID] = nil
                connectionStates[accountID] = .disconnected
            case let .streamError(condition, text):
                smResumeStates[accountID] = smModules[accountID]?.resumeState
                let message = text ?? condition?.rawValue ?? "Stream error"
                connectionStates[accountID] = .error(message)
                scheduleReconnect(accountID: accountID)
            case let .connectionLost(message):
                smResumeStates[accountID] = smModules[accountID]?.resumeState
                connectionStates[accountID] = .error(message)
                scheduleReconnect(accountID: accountID)
            }
            smModules[accountID] = nil
            clients[accountID] = nil
            eventTasks[accountID]?.cancel()
            eventTasks[accountID] = nil
        case let .authenticationFailed(message):
            connectionStates[accountID] = .error(message)
        case .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageError,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .pepItemsPublished, .pepItemsRetracted,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            break
        }

        onEvent?(event, accountID)
    }

    // MARK: - Private: Reconnection

    private func cancelReconnect(for accountID: UUID, resetAttempts: Bool) {
        reconnectTasks[accountID]?.cancel()
        reconnectTasks[accountID] = nil
        if resetAttempts {
            reconnectAttempts[accountID] = 0
        }
    }

    private func scheduleReconnect(accountID: UUID) {
        let attempt = reconnectAttempts[accountID] ?? 0
        guard attempt < 5 else { return }

        reconnectAttempts[accountID] = attempt + 1
        let delay = min(pow(2.0, Double(attempt)), 30.0)

        reconnectTasks[accountID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? await self?.performConnect(accountID: accountID)
        }
    }
}
