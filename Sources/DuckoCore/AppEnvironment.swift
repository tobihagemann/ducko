import DuckoXMPP
import Foundation

@MainActor @Observable
public final class AppEnvironment {
    public let accountService: AccountService
    public let chatService: ChatService
    public let presenceService: PresenceService
    public let fileTransferService: FileTransferService
    public let linkPreviewService: LinkPreviewService
    public let messageFilterPipeline: MessageFilterPipeline

    public init(
        store: any PersistenceStore,
        linkPreviewFetcher: any LinkPreviewFetcher = NoOpLinkPreviewFetcher(),
        onExternalEvent: (@Sendable (XMPPEvent, UUID) -> Void)? = nil
    ) {
        let pipeline = MessageFilterPipeline()
        let chatService = ChatService(store: store, filterPipeline: pipeline)
        let presenceService = PresenceService()
        let accountService = AccountService(store: store)
        let fileTransferService = FileTransferService()
        let linkPreviewService = LinkPreviewService(fetcher: linkPreviewFetcher, store: store)

        accountService.onEvent = { [weak chatService, weak presenceService] event, accountID in
            Task { @MainActor in
                await chatService?.handleEvent(event, accountID: accountID)
                presenceService?.handleEvent(event, accountID: accountID)
            }
            onExternalEvent?(event, accountID)
        }

        chatService.setAccountService(accountService)

        self.accountService = accountService
        self.chatService = chatService
        self.presenceService = presenceService
        self.fileTransferService = fileTransferService
        self.linkPreviewService = linkPreviewService
        self.messageFilterPipeline = pipeline
    }
}
