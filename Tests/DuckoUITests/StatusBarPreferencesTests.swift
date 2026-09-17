import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct StatusBarPreferencesTests {
    @Test func `identity account ID defaults to nil`() {
        let fixture = PreferencesFixture()
        #expect(StatusBarPreferences(defaults: fixture.defaults).identityAccountID == nil)
    }

    @Test func `identity account ID persists`() {
        let fixture = PreferencesFixture()
        let id = UUID()
        let prefs = StatusBarPreferences(defaults: fixture.defaults)
        prefs.identityAccountID = id
        #expect(StatusBarPreferences(defaults: fixture.defaults).identityAccountID == id)
    }

    @Test func `clearing identity account ID round-trips to nil`() {
        let fixture = PreferencesFixture()
        let prefs = StatusBarPreferences(defaults: fixture.defaults)
        prefs.identityAccountID = UUID()
        prefs.identityAccountID = nil
        #expect(StatusBarPreferences(defaults: fixture.defaults).identityAccountID == nil)
    }

    @Test func `saved messages round-trip per category`() {
        let fixture = PreferencesFixture()
        let prefs = StatusBarPreferences(defaults: fixture.defaults)
        prefs.saveMessage("Lunch", for: .away)
        prefs.saveMessage("Heads down", for: .dnd)

        let reloaded = StatusBarPreferences(defaults: fixture.defaults)
        #expect(reloaded.savedMessages(for: .away) == ["Lunch"])
        #expect(reloaded.savedMessages(for: .dnd) == ["Heads down"])
        #expect(reloaded.savedMessages(for: .available) == [])
        #expect(StatusBarPreferences(defaults: PreferencesFixture().defaults).savedMessages.isEmpty)
    }

    @Test func `saving caps at five most-recent and dedupes`() {
        let fixture = PreferencesFixture()
        let prefs = StatusBarPreferences(defaults: fixture.defaults)
        for i in 1 ... 7 {
            prefs.saveMessage("msg \(i)", for: .away)
        }
        #expect(prefs.savedMessages(for: .away) == ["msg 7", "msg 6", "msg 5", "msg 4", "msg 3"])

        // Re-saving an existing message moves it to the front without growing the list.
        prefs.saveMessage("msg 4", for: .away)
        #expect(prefs.savedMessages(for: .away) == ["msg 4", "msg 7", "msg 6", "msg 5", "msg 3"])
    }

    @Test func `whitespace-only saved message is ignored`() {
        let fixture = PreferencesFixture()
        let prefs = StatusBarPreferences(defaults: fixture.defaults)
        prefs.saveMessage("   ", for: .away)
        #expect(prefs.savedMessages(for: .away) == [])
    }

    @Test func `removeMessage deletes a saved entry and persists`() {
        let fixture = PreferencesFixture()
        let prefs = StatusBarPreferences(defaults: fixture.defaults)
        prefs.saveMessage("Lunch", for: .away)
        prefs.saveMessage("Errand", for: .away)
        prefs.removeMessage("Lunch", for: .away)
        #expect(prefs.savedMessages(for: .away) == ["Errand"])
        #expect(StatusBarPreferences(defaults: fixture.defaults).savedMessages(for: .away) == ["Errand"])
    }
}
