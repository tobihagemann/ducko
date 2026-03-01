import DuckoCore
import Foundation
import SwiftUI

@MainActor @Observable
public final class ChatTabManager {
    struct Tab: Identifiable {
        let id: UUID
        let jidString: String
        var windowState: ChatWindowState?
    }

    var tabs: [Tab] = []
    public var selectedTabID: UUID?

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    public init() {}

    func openTab(jidString: String, environment: AppEnvironment) -> UUID {
        // Dedup by JID
        if let existing = tabs.first(where: { $0.jidString == jidString }) {
            selectedTabID = existing.id
            return existing.id
        }

        let state = ChatWindowState(jidString: jidString, environment: environment)
        let tab = Tab(id: UUID(), jidString: jidString, windowState: state)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab.id
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedTabID == id
        tabs.remove(at: index)

        if wasSelected {
            // Select adjacent tab
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectedTabID = tabs[newIndex].id
            }
        }
    }

    public func closeSelectedTab() {
        guard tabs.count > 1, let selectedTabID else { return }
        closeTab(id: selectedTabID)
    }

    public func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectedTabID = tabs[index].id
    }

    public func selectNextTab() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabID = tabs[nextIndex].id
    }

    public func toggleSearch() {
        guard let windowState = selectedTab?.windowState else { return }
        if windowState.isSearching {
            windowState.dismissSearch()
        } else {
            windowState.isSearching = true
        }
    }

    public func selectPreviousTab() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[prevIndex].id
    }
}
