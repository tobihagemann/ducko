import Foundation
import Testing
@testable import DuckoUI

struct ContactListSortTests {
    @Test func `sort mode labels`() {
        #expect(ContactListSortMode.alphabetical.label == "Alphabetical")
        #expect(ContactListSortMode.byStatus.label == "By Status")
        #expect(ContactListSortMode.recentConversation.label == "Recent Conversation")
    }

    @Test func `all cases contains all modes`() {
        #expect(ContactListSortMode.allCases.count == 3)
    }

    @Test func `sort mode raw values`() {
        #expect(ContactListSortMode(rawValue: "alphabetical") == .alphabetical)
        #expect(ContactListSortMode(rawValue: "byStatus") == .byStatus)
        #expect(ContactListSortMode(rawValue: "recentConversation") == .recentConversation)
        #expect(ContactListSortMode(rawValue: "invalid") == nil)
    }

    @Test func `sort mode identity`() {
        for mode in ContactListSortMode.allCases {
            #expect(mode.id == mode.rawValue)
        }
    }
}
