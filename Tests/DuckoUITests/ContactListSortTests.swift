import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

struct ContactListSortTests {
    @Test func sortModeLabels() {
        #expect(ContactListSortMode.alphabetical.label == "Alphabetical")
        #expect(ContactListSortMode.byStatus.label == "By Status")
        #expect(ContactListSortMode.recentConversation.label == "Recent Conversation")
    }

    @Test func allCasesContainsAllModes() {
        #expect(ContactListSortMode.allCases.count == 3)
    }

    @Test func sortModeRawValues() {
        #expect(ContactListSortMode(rawValue: "alphabetical") == .alphabetical)
        #expect(ContactListSortMode(rawValue: "byStatus") == .byStatus)
        #expect(ContactListSortMode(rawValue: "recentConversation") == .recentConversation)
        #expect(ContactListSortMode(rawValue: "invalid") == nil)
    }

    @Test func sortModeIdentity() {
        for mode in ContactListSortMode.allCases {
            #expect(mode.id == mode.rawValue)
        }
    }
}
