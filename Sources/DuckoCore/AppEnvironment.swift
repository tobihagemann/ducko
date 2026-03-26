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

        accountService.onEvent = { [weak chatService, weak presenceService, weak rosterService, weak fileTransferService, weak bookmarksService, weak avatarService, weak omemoService] event, accountID in
            Task { @MainActor in
                await chatService?.handleEvent(event, accountID: accountID)
                presenceService?.handleEvent(event, accountID: accountID)
                await rosterService?.handleEvent(event, accountID: accountID)
                fileTransferService?.handleJingleEvent(event, accountID: accountID)
                await bookmarksService?.handleEvent(event, accountID: accountID)
                await avatarService?.handleEvent(event, accountID: accountID)
                await omemoService?.handleEvent(event, accountID: accountID)
            }
            onExternalEvent?(event, accountID)
        }

        Self.registerFilters(pipeline: pipeline, linkPreviewService: linkPreviewService)

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

        wireServices()
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

    private static func registerFilters(pipeline: MessageFilterPipeline, linkPreviewService: LinkPreviewService) {
        Task {
            await pipeline.register(StylingFilter())
            await pipeline.register(LinkDetectionFilter())
            await pipeline.register(EmojiFilter())
            await pipeline.register(MentionFilter())
            await pipeline.register(LinkPreviewFilter(previewService: linkPreviewService))
        }
    }
}
