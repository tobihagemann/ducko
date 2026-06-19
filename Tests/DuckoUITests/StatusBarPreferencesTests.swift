import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

private nonisolated(unsafe) let defaults = PreferencesDefaults.store

/// Serialized because every test mutates the same two shared `PreferencesDefaults` keys; parallel runs would
/// race on them.
@Suite(.serialized)
@MainActor
struct StatusBarPreferencesTests {
    private func clear() {
        defaults.removeObject(forKey: "statusBarIdentityAccountID")
        defaults.removeObject(forKey: "statusBarSavedMessages")
    }

    @Test func `identity account ID defaults to nil`() {
        clear()
        defer { clear() }
        #expect(StatusBarPreferences().identityAccountID == nil)
    }

    @Test func `identity account ID persists`() {
        clear()
        defer { clear() }
        let id = UUID()
        let prefs = StatusBarPreferences()
        prefs.identityAccountID = id
        #expect(StatusBarPreferences().identityAccountID == id)
    }

    @Test func `clearing identity account ID round-trips to nil`() {
        clear()
        defer { clear() }
        let prefs = StatusBarPreferences()
        prefs.identityAccountID = UUID()
        prefs.identityAccountID = nil
        #expect(StatusBarPreferences().identityAccountID == nil)
    }

    @Test func `saved messages round-trip per category`() {
        clear()
        defer { clear() }
        let prefs = StatusBarPreferences()
        prefs.saveMessage("Lunch", for: .away)
        prefs.saveMessage("Heads down", for: .dnd)

        let reloaded = StatusBarPreferences()
        #expect(reloaded.savedMessages(for: .away) == ["Lunch"])
        #expect(reloaded.savedMessages(for: .dnd) == ["Heads down"])
        #expect(reloaded.savedMessages(for: .available) == [])
    }

    @Test func `saving caps at five most-recent and dedupes`() {
        clear()
        defer { clear() }
        let prefs = StatusBarPreferences()
        for i in 1 ... 7 {
            prefs.saveMessage("msg \(i)", for: .away)
        }
        #expect(prefs.savedMessages(for: .away) == ["msg 7", "msg 6", "msg 5", "msg 4", "msg 3"])

        // Re-saving an existing message moves it to the front without growing the list.
        prefs.saveMessage("msg 4", for: .away)
        #expect(prefs.savedMessages(for: .away) == ["msg 4", "msg 7", "msg 6", "msg 5", "msg 3"])
    }

    @Test func `whitespace-only saved message is ignored`() {
        clear()
        defer { clear() }
        let prefs = StatusBarPreferences()
        prefs.saveMessage("   ", for: .away)
        #expect(prefs.savedMessages(for: .away) == [])
    }

    @Test func `removeMessage deletes a saved entry and persists`() {
        clear()
        defer { clear() }
        let prefs = StatusBarPreferences()
        prefs.saveMessage("Lunch", for: .away)
        prefs.saveMessage("Errand", for: .away)
        prefs.removeMessage("Lunch", for: .away)
        #expect(prefs.savedMessages(for: .away) == ["Errand"])
        #expect(StatusBarPreferences().savedMessages(for: .away) == ["Errand"])
    }
}
