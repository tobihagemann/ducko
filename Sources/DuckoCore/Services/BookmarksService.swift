import DuckoXMPP
import Foundation
import os

enum BookmarksError: Error, LocalizedError {
    case invalidJID(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case let .invalidJID(jid):
            return "Invalid JID: \(jid)"
        case .notConnected:
            return "Not connected to XMPP server"
        }
    }
}

@MainActor @Observable
public final class BookmarksService {
    private var bookmarksByAccount: [UUID: [RoomBookmark]] = [:]

    public var bookmarks: [RoomBookmark] {
        bookmarksByAccount.values.flatMap(\.self)
    }

    public var autoJoinEnabled: Bool = false

    private weak var accountService: AccountService?
    private weak var chatService: ChatService?
    private let log = Logger(subsystem: "ducko", category: "BookmarksService")

    public init() {}

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setChatService(_ service: ChatService) {
        chatService = service
    }

    // MARK: - Public API

    public func loadBookmarks(accountID: UUID) async {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }

        do {
            let items = try await pepModule.retrieveItems(node: XMPPNamespaces.bookmarks2)
            let parsed = items.compactMap { Bookmark.parse(itemID: $0.id, payload: $0.payload) }
            bookmarksByAccount[accountID] = parsed.map { mapToRoomBookmark($0) }
            await autojoinRooms(from: parsed, accountID: accountID)
        } catch {
            log.warning("Failed to load bookmarks: \(error.localizedDescription)")
        }
    }

    public func addBookmark(_ bookmark: RoomBookmark, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else {
            throw BookmarksError.notConnected
        }
        guard let pepModule = await client.module(ofType: PEPModule.self) else {
            throw BookmarksError.notConnected
        }

        guard let jid = BareJID.parse(bookmark.jidString) else {
            throw BookmarksError.invalidJID(bookmark.jidString)
        }
        let xmppBookmark = Bookmark(
            jid: jid,
            name: bookmark.name,
            autojoin: bookmark.autojoin,
            nickname: bookmark.nickname,
            password: bookmark.password
        )
        try await pepModule.publishItem(
            node: XMPPNamespaces.bookmarks2,
            itemID: jid.description,
            payload: xmppBookmark.toXMLElement(),
            options: Bookmark.publishOptions
        )

        // Merge into local state
        upsertBookmark(bookmark, accountID: accountID)
    }

    public func removeBookmark(jidString: String, accountID: UUID) async throws {
        guard let client = accountService?.client(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }

        try await pepModule.retractItem(node: XMPPNamespaces.bookmarks2, itemID: jidString)
        bookmarksByAccount[accountID]?.removeAll { $0.jidString == jidString }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case .connected:
            await loadBookmarks(accountID: accountID)
        case let .pepItemsPublished(from, node, items)
            where node == XMPPNamespaces.bookmarks2:
            await handleBookmarksPublished(from: from, items: items, accountID: accountID)
        case let .pepItemsRetracted(from, node, itemIDs)
            where node == XMPPNamespaces.bookmarks2:
            await handleBookmarksRetracted(from: from, itemIDs: itemIDs, accountID: accountID)
        case .disconnected:
            bookmarksByAccount.removeValue(forKey: accountID)
        case .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleFileRequestReceived, .jingleChecksumReceived, .jingleChecksumMismatch,
             .jingleContentAddReceived, .jingleContentAccepted,
             .jingleContentRejected, .jingleContentRemoved,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    // MARK: - Private

    private func handleBookmarksPublished(from: BareJID, items: [PEPItem], accountID: UUID) async {
        // Only process our own bookmarks
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }),
              from == account.jid else { return }

        let parsed = items.compactMap { Bookmark.parse(itemID: $0.id, payload: $0.payload) }

        var newBookmarks: [Bookmark] = []
        for bookmark in parsed {
            let roomBookmark = mapToRoomBookmark(bookmark)
            let isNew = upsertBookmark(roomBookmark, accountID: accountID)
            if isNew {
                newBookmarks.append(bookmark)
            }
        }

        await autojoinRooms(from: newBookmarks, accountID: accountID)
    }

    private func handleBookmarksRetracted(from: BareJID, itemIDs: [String], accountID: UUID) async {
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }),
              from == account.jid else { return }

        for itemID in itemIDs {
            bookmarksByAccount[accountID]?.removeAll { $0.jidString == itemID }
            try? await chatService?.leaveRoom(jidString: itemID, accountID: accountID)
        }
    }

    private func autojoinRooms(from bookmarks: [Bookmark], accountID: UUID) async {
        guard autoJoinEnabled else { return }
        let account = accountService?.accounts.first(where: { $0.id == accountID })
        let fallbackNickname = account?.jid.localPart ?? ""

        for bookmark in bookmarks where bookmark.autojoin {
            let nickname = bookmark.nickname ?? fallbackNickname
            guard !nickname.isEmpty else { continue }
            try? await chatService?.joinRoom(
                jid: bookmark.jid,
                nickname: nickname,
                password: bookmark.password,
                accountID: accountID
            )
        }
    }

    @discardableResult
    private func upsertBookmark(_ bookmark: RoomBookmark, accountID: UUID) -> Bool {
        if let index = bookmarksByAccount[accountID]?.firstIndex(where: { $0.jidString == bookmark.jidString }) {
            bookmarksByAccount[accountID]?[index] = bookmark
            return false
        } else {
            bookmarksByAccount[accountID, default: []].append(bookmark)
            return true
        }
    }

    private func mapToRoomBookmark(_ bookmark: Bookmark) -> RoomBookmark {
        RoomBookmark(
            jidString: bookmark.jid.description,
            name: bookmark.name,
            autojoin: bookmark.autojoin,
            nickname: bookmark.nickname,
            password: bookmark.password
        )
    }
}
