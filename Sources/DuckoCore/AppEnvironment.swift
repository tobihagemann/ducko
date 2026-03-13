import DuckoXMPP
import Foundation

@MainActor @Observable
public final class AppEnvironment {
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

    public init(
        store: any PersistenceStore,
        credentialStore: (any CredentialStore)? = nil,
        linkPreviewFetcher: any LinkPreviewFetcher = NoOpLinkPreviewFetcher(),
        onExternalEvent: (@Sendable (XMPPEvent, UUID) -> Void)? = nil
    ) {
        let resolvedCredentialStore = credentialStore ?? CredentialStoreFactory.makeDefault()

        let pipeline = MessageFilterPipeline()
        let chatService = ChatService(store: store, filterPipeline: pipeline)
        let presenceService = PresenceService()
        let rosterService = RosterService(store: store)
        let accountService = AccountService(store: store, credentialStore: resolvedCredentialStore)
        let bookmarksService = BookmarksService()
        bookmarksService.autoJoinEnabled = true
        let avatarService = AvatarService(store: store)
        let profileService = ProfileService()
        let fileTransferService = FileTransferService()
        let linkPreviewService = LinkPreviewService(fetcher: linkPreviewFetcher, store: store)

        accountService.onEvent = { [weak chatService, weak presenceService, weak rosterService, weak fileTransferService, weak bookmarksService, weak avatarService] event, accountID in
            Task { @MainActor in
                await chatService?.handleEvent(event, accountID: accountID)
                presenceService?.handleEvent(event, accountID: accountID)
                await rosterService?.handleEvent(event, accountID: accountID)
                fileTransferService?.handleJingleEvent(event, accountID: accountID)
                await bookmarksService?.handleEvent(event, accountID: accountID)
                await avatarService?.handleEvent(event, accountID: accountID)
            }
            onExternalEvent?(event, accountID)
        }

        chatService.setAccountService(accountService)
        presenceService.setAccountService(accountService)
        rosterService.setAccountService(accountService)
        rosterService.setPresenceService(presenceService)
        bookmarksService.setAccountService(accountService)
        bookmarksService.setChatService(chatService)
        avatarService.setAccountService(accountService)
        avatarService.setRosterService(rosterService)
        profileService.setAccountService(accountService)
        fileTransferService.setAccountService(accountService)
        fileTransferService.setChatService(chatService)

        Self.registerFilters(pipeline: pipeline, linkPreviewService: linkPreviewService)

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
    }

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
