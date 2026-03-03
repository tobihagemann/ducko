import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ChatTabManagerTests {
    @Test func `open tab creates tab`() {
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

    @Test func `close tab selects adjacent`() {
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

    @Test func `close last tab clears selection`() {
        let manager = ChatTabManager()

        let tab = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        manager.tabs = [tab]
        manager.selectedTabID = tab.id

        manager.closeTab(id: tab.id)

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedTabID == nil)
    }

    @Test func `select next tab wraps around`() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        manager.tabs = [tab1, tab2]
        manager.selectedTabID = tab2.id

        manager.selectNextTab()
        #expect(manager.selectedTabID == tab1.id)
    }

    @Test func `select previous tab wraps around`() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        manager.tabs = [tab1, tab2]
        manager.selectedTabID = tab1.id

        manager.selectPreviousTab()
        #expect(manager.selectedTabID == tab2.id)
    }

    @Test func `select tab by index`() {
        let manager = ChatTabManager()

        let tab1 = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        let tab2 = ChatTabManager.Tab(id: UUID(), jidString: "bob@example.com", windowState: nil)
        let tab3 = ChatTabManager.Tab(id: UUID(), jidString: "carol@example.com", windowState: nil)
        manager.tabs = [tab1, tab2, tab3]
        manager.selectedTabID = tab1.id

        manager.selectTab(at: 2)
        #expect(manager.selectedTabID == tab3.id)
    }

    @Test func `select tab out of bounds ignored`() {
        let manager = ChatTabManager()

        let tab = ChatTabManager.Tab(id: UUID(), jidString: "alice@example.com", windowState: nil)
        manager.tabs = [tab]
        manager.selectedTabID = tab.id

        manager.selectTab(at: 5)
        #expect(manager.selectedTabID == tab.id)
    }

    @Test func `close non selected tab keeps selection`() {
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
