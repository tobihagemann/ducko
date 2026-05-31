import DuckoXMPP
import Foundation

@MainActor @Observable
public final class AppEnvironment {
    public nonisolated let store: any PersistenceStore
    public nonisolated let transcripts: any TranscriptStore
    public nonisolated let credentialStore: any CredentialStore
    public let accountService: AccountService
    public let chatService: ChatService
    public let presenceService: PresenceService
    public let rosterService: RosterService
    public let fileTransferService: FileTransferService
    public let bookmarksService: BookmarksService
    public let avatarService: AvatarService
    public let profileService: ProfileService
    public let linkPreviewService: LinkPreviewService
    public let omemoService: OMEMOService

    private let filterPipeline: MessageFilterPipeline
    private let onExternalEvent: (@Sendable (XMPPEvent, UUID) -> Void)?
    /// Per-event dispatch tasks and the one-shot filter-registration task, each keyed by a UUID and
    /// self-removing on completion. Drained by `shutdown(within:)` so they can't race teardown.
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        store: any PersistenceStore,
        transcripts: any TranscriptStore,
        credentialStore: (any CredentialStore)? = nil,
        omemoStore: (any OMEMOStore)? = nil,
        linkPreviewFetcher: any LinkPreviewFetcher = NoOpLinkPreviewFetcher(),
        onExternalEvent: (@Sendable (XMPPEvent, UUID) -> Void)? = nil
    ) {
        let resolvedCredentialStore = credentialStore ?? CredentialStoreFactory.makeDefault()

        let pipeline = MessageFilterPipeline()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: pipeline)
        let presenceService = PresenceService()
        let rosterService = RosterService(store: store)
        let accountService = AccountService(store: store, credentialStore: resolvedCredentialStore)
        let bookmarksService = BookmarksService()
        bookmarksService.autoJoinEnabled = true
        let avatarService = AvatarService(store: store)
        let profileService = ProfileService()
        let fileTransferService = FileTransferService()
        let linkPreviewService = LinkPreviewService(fetcher: linkPreviewFetcher, store: store)
        let omemoService = OMEMOService(omemoStore: omemoStore ?? NoOpOMEMOStore())

        self.store = store
        self.transcripts = transcripts
        self.credentialStore = resolvedCredentialStore
        self.accountService = accountService
        self.chatService = chatService
        self.presenceService = presenceService
        self.rosterService = rosterService
        self.bookmarksService = bookmarksService
        self.avatarService = avatarService
        self.profileService = profileService
        self.fileTransferService = fileTransferService
        self.linkPreviewService = linkPreviewService
        self.omemoService = omemoService
        self.filterPipeline = pipeline
        self.onExternalEvent = onExternalEvent

        wireServices()
        wireEventDispatch()
        registerFilters()
    }

    private func wireServices() {
        chatService.setAccountService(accountService)
        chatService.setOMEMOService(omemoService)
        presenceService.setAccountService(accountService)
        rosterService.setAccountService(accountService)
        rosterService.setPresenceService(presenceService)
        bookmarksService.setAccountService(accountService)
        bookmarksService.setChatService(chatService)
        avatarService.setAccountService(accountService)
        avatarService.setRosterService(rosterService)
        avatarService.setPresenceService(presenceService)
        profileService.setAccountService(accountService)
        fileTransferService.setAccountService(accountService)
        fileTransferService.setChatService(chatService)
        omemoService.setAccountService(accountService)
        omemoService.setChatService(chatService)
        accountService.setOMEMOService(omemoService)
    }

    /// Fans each account event out to the consuming services on a stored, self-removing task so the
    /// per-event dispatch can be drained on shutdown. Assigned after stored-property initialization so the
    /// closure reaches the services through `self`.
    private func wireEventDispatch() {
        accountService.onEvent = { [weak self] event, accountID in
            guard let self else { return }
            let taskID = UUID()
            pendingTasks[taskID] = Task { @MainActor [weak self] in
                defer { self?.pendingTasks[taskID] = nil }
                guard let self else { return }
                // Shutdown cancels this task; bail before fanning out so a cancelled dispatch can't spawn
                // a child service task after `shutdown` snapshotted the drain stores.
                if Task.isCancelled { return }
                await chatService.handleEvent(event, accountID: accountID)
                await presenceService.handleEvent(event, accountID: accountID)
                await rosterService.handleEvent(event, accountID: accountID)
                fileTransferService.handleJingleEvent(event, accountID: accountID)
                await bookmarksService.handleEvent(event, accountID: accountID)
                await avatarService.handleEvent(event, accountID: accountID)
                await omemoService.handleEvent(event, accountID: accountID)
            }
            onExternalEvent?(event, accountID)
        }
    }

    // MARK: - Shutdown

    /// Cancels and bounded-awaits the fire-and-forget service tasks spawned outside the account-teardown
    /// path (per-event dispatch, filter registration, ChatService MAM/nick/typing-debounce tasks,
    /// FileTransferService Jingle tasks). Does not disconnect accounts — that stays with
    /// `AccountService.disconnectAll`.
    public func shutdown(within deadline: Duration) async {
        let tasks = takePendingTasks()
            + chatService.takePendingTasks()
            + fileTransferService.takePendingTasks()
        for task in tasks {
            task.cancel()
        }
        await runBounded(within: deadline) {
            for task in tasks {
                _ = await task.value
            }
        }
    }

    /// Returns this environment's in-flight event/filter task handles and clears the store, so
    /// `shutdown(within:)` operates on a captured snapshot rather than the live store.
    private func takePendingTasks() -> [Task<Void, Never>] {
        let tasks = Array(pendingTasks.values)
        pendingTasks.removeAll()
        return tasks
    }

    #if DEBUG
        /// Test seam: lets `shutdown` draining run against a task of controlled duration.
        func registerPendingTaskForTesting(_ task: Task<Void, Never>) {
            pendingTasks[UUID()] = task
        }
    #endif

    // MARK: - Account Teardown

    /// Removes a local account: disconnect, optionally delete transcripts, delete account data.
    /// All steps are fail-safe — errors are suppressed since this is cleanup.
    public func removeAccount(_ id: UUID, includeHistory: Bool) async {
        let accountJID = accountService.accounts.first(where: { $0.id == id })?.jid.description
        await accountService.disconnect(accountID: id)
        if includeHistory {
            try? await chatService.deleteTranscriptsForAccount(id)
            try? await store.deleteConversations(for: id)
        } else if let accountJID {
            try? await store.unlinkConversations(for: id, restoreImportSourceJID: accountJID)
        }
        try? await store.deleteContacts(for: id)
        try? await accountService.deleteAccount(id)
    }

    /// Cancels server-side registration (XEP-0077), then removes the account locally.
    /// Throws only if server-side cancellation fails. Local cleanup is fail-safe.
    public func cancelAccount(_ id: UUID, includeHistory: Bool) async throws {
        try await accountService.cancelRegistration(accountID: id)
        await removeAccount(id, includeHistory: includeHistory)
    }

    // MARK: - Filters

    private func registerFilters() {
        let taskID = UUID()
        pendingTasks[taskID] = Task { [weak self] in
            defer { self?.pendingTasks[taskID] = nil }
            guard let self else { return }
            await filterPipeline.register(StylingFilter())
            await filterPipeline.register(LinkDetectionFilter())
            await filterPipeline.register(EmojiFilter())
            await filterPipeline.register(MentionFilter())
            await filterPipeline.register(LinkPreviewFilter(previewService: linkPreviewService))
        }
    }
}
