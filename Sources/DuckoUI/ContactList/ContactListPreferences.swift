import DuckoCore
import Foundation
import SwiftUI

@MainActor @Observable
final class ContactListPreferences {
    private enum Keys {
        static let sortMode = "contactListSortMode"
        static let hideOffline = "contactListHideOffline"
        static let collapsedGroups = "contactListCollapsedGroups"
    }

    private static let defaults = PreferencesDefaults.store

    var sortMode: ContactListSortMode {
        didSet { sortModeStorage = sortMode.rawValue }
    }

    var hideOffline: Bool {
        didSet { hideOfflineStorage = hideOffline }
    }

    var collapsedGroups: Set<String> {
        didSet { saveCollapsedGroups() }
    }

    @ObservationIgnored
    @AppStorage(Keys.sortMode, store: ContactListPreferences.defaults) private var sortModeStorage = ContactListSortMode.alphabetical.rawValue

    @ObservationIgnored
    @AppStorage(Keys.hideOffline, store: ContactListPreferences.defaults) private var hideOfflineStorage = false

    @ObservationIgnored
    @AppStorage(Keys.collapsedGroups, store: ContactListPreferences.defaults) private var collapsedGroupsStorage = "[]"

    init() {
        self.sortMode = ContactListSortMode(rawValue: ContactListPreferences.defaults.string(forKey: Keys.sortMode) ?? "") ?? .alphabetical
        self.hideOffline = ContactListPreferences.defaults.bool(forKey: Keys.hideOffline)
        self.collapsedGroups = Self.loadCollapsedGroups()
    }

    func isGroupExpanded(_ name: String) -> Bool {
        !collapsedGroups.contains(name)
    }

    func toggleGroupExpanded(_ name: String) {
        if collapsedGroups.contains(name) {
            collapsedGroups.remove(name)
        } else {
            collapsedGroups.insert(name)
        }
    }

    // MARK: - Private

    private func saveCollapsedGroups() {
        if let data = try? JSONEncoder().encode(Array(collapsedGroups)),
           let json = String(data: data, encoding: .utf8) {
            collapsedGroupsStorage = json
        }
    }

    private static func loadCollapsedGroups() -> Set<String> {
        let json = defaults.string(forKey: Keys.collapsedGroups) ?? "[]"
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }
}
