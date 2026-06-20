import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

enum BookmarksServicePurgeTests {
    struct Purge {
        @Test
        @MainActor
        func `Disconnect event clears the account's bookmarks`() async {
            let service = BookmarksService()
            let accountID = UUID()
            service.setBookmarksForTesting([RoomBookmark(jidString: "room@conference.example.com")], accountID: accountID)
            #expect(!service.bookmarks.isEmpty)

            await service.handleEvent(.disconnected(.requested), accountID: accountID)
            #expect(service.bookmarks.isEmpty)
        }

        @Test
        @MainActor
        func `purgeAccount clears only the targeted account's bookmarks`() {
            let service = BookmarksService()
            let accountA = UUID()
            let accountB = UUID()
            service.setBookmarksForTesting([RoomBookmark(jidString: "room-a@conference.example.com")], accountID: accountA)
            service.setBookmarksForTesting([RoomBookmark(jidString: "room-b@conference.example.com")], accountID: accountB)
            #expect(service.bookmarks.count == 2)

            service.purgeAccount(accountA)

            #expect(service.bookmarks.count == 1)
            #expect(service.bookmarks.first?.jidString == "room-b@conference.example.com")
        }
    }
}
