import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ChatTabManagerTests {
    @Test func openTabCreatesTab() {
        let manager = ChatTabManager()
        #expect(manager.tabs.isEmpty)

        // Cannot create real AppEnvironment in tests, so test the pure logic
        // by directly manipulating tabs
        let tab = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        manager.tabs.append(tab)
        manager.selectedTabID = tab.id

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabID == tab.id)
        #expect(manager.selectedTab?.jidString == "alice@example.com")
    }

    @Test func closeTabSelectsAdjacent() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        let tab3 = ChatTabManager.Tab(id: UUID(), jidString: "carol@example.com", windowState: nil)
        manager.tabs = [tab1, tab2, tab3]
        manager.selectedTabID = tab2.id

        manager.closeTab(id: tab2.id)

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTabID == tab3.id)
    }

    @Test func closeLastTabClearsSelection() {
        let manager = ChatTabManager()

        let tab = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        manager.tabs = [tab]
        manager.selectedTabID = tab.id

        manager.closeTab(id: tab.id)

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedTabID == nil)
    }

    @Test func selectNextTabWrapsAround() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        manager.tabs = [tab1, tab2]
        manager.selectedTabID = tab2.id

        manager.selectNextTab()
        #expect(manager.selectedTabID == tab1.id)
    }

    @Test func selectPreviousTabWrapsAround() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        manager.tabs = [tab1, tab2]
        manager.selectedTabID = tab1.id

        manager.selectPreviousTab()
        #expect(manager.selectedTabID == tab2.id)
    }

    @Test func selectTabByIndex() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        let tab3 = ChatTabManager.Tab(id: UUID(), jidString: "carol@example.com", windowState: nil)
        manager.tabs = [tab1, tab2, tab3]
        manager.selectedTabID = tab1.id

        manager.selectTab(at: 2)
        #expect(manager.selectedTabID == tab3.id)
    }

    @Test func selectTabOutOfBoundsIgnored() {
        let manager = ChatTabManager()

        let tab = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        manager.tabs = [tab]
        manager.selectedTabID = tab.id

        manager.selectTab(at: 5)
        #expect(manager.selectedTabID == tab.id)
    }

    @Test func closeNonSelectedTabKeepsSelection() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        manager.tabs = [tab1, tab2]
        manager.selectedTabID = tab1.id

        manager.closeTab(id: tab2.id)

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabID == tab1.id)
    }
}
