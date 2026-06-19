import DuckoCore
import Foundation
import SwiftUI

/// Shared across the Contacts "me" header dropdown and the Status preferences pane, so saved-status edits in
/// Preferences reflect live in the header. Owned once at the app level and injected into both scenes.
@MainActor @Observable
public final class StatusBarPreferences {
    private enum Keys {
        static let identityAccountID = "statusBarIdentityAccountID"
        static let savedMessages = "statusBarSavedMessages"
    }

    private static let defaults = PreferencesDefaults.store

    /// How many recent custom messages to keep per presence category.
    private static let maxSavedPerCategory = 5

    var identityAccountID: UUID? {
        didSet { identityAccountIDStorage = identityAccountID?.uuidString ?? "" }
    }

    var savedMessages: [PresenceService.PresenceStatus: [String]] {
        didSet { saveSavedMessages() }
    }

    @ObservationIgnored
    @AppStorage(Keys.identityAccountID, store: StatusBarPreferences.defaults) private var identityAccountIDStorage = ""

    @ObservationIgnored
    @AppStorage(Keys.savedMessages, store: StatusBarPreferences.defaults) private var savedMessagesStorage = "{}"

    public init() {
        self.identityAccountID = StatusBarPreferences.defaults.string(forKey: Keys.identityAccountID)
            .flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
        self.savedMessages = Self.loadSavedMessages()
    }

    func savedMessages(for status: PresenceService.PresenceStatus) -> [String] {
        savedMessages[status] ?? []
    }

    func saveMessage(_ message: String, for status: PresenceService.PresenceStatus) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var messages = savedMessages[status] ?? []
        messages.removeAll { $0 == trimmed }
        messages.insert(trimmed, at: 0)
        savedMessages[status] = Array(messages.prefix(Self.maxSavedPerCategory))
    }

    func removeMessage(_ message: String, for status: PresenceService.PresenceStatus) {
        guard var messages = savedMessages[status] else { return }
        messages.removeAll { $0 == message }
        savedMessages[status] = messages.isEmpty ? nil : messages
    }

    /// Persists as JSON keyed by `PresenceStatus.rawValue` — encoding the `[PresenceStatus: …]` dict directly
    /// would emit a flat array, so map to `[String: [String]]` first.
    private func saveSavedMessages() {
        let keyed = Dictionary(uniqueKeysWithValues: savedMessages.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(keyed),
           let json = String(data: data, encoding: .utf8) {
            savedMessagesStorage = json
        }
    }

    private static func loadSavedMessages() -> [PresenceService.PresenceStatus: [String]] {
        let json = defaults.string(forKey: Keys.savedMessages) ?? "{}"
        guard let data = json.data(using: .utf8),
              let keyed = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return keyed.reduce(into: [:]) { result, entry in
            if let status = PresenceService.PresenceStatus(rawValue: entry.key) {
                result[status] = entry.value
            }
        }
    }
}
