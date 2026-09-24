import DuckoCore
import Testing
@testable import DuckoUI

struct StatusSummaryTests {
    private static func shown(_ statuses: PresenceService.PresenceStatus...) -> StatusSummary.Presences {
        statuses.map { ($0, nil) }
    }

    @Test func `the label is the plain status when every account agrees`() {
        #expect(StatusSummary.label(for: (.available, nil), presences: Self.shown(.available, .available)) == "Available")
    }

    @Test func `the label counts the accounts showing another status in canonical order`() {
        let presences = Self.shown(.available, .offline, .away, .offline)
        #expect(StatusSummary.label(for: (.available, nil), presences: presences) == "Available · 1 Away, 2 Offline")
    }

    @Test func `the label leads with the shown account's own status, not the most common one`() {
        #expect(StatusSummary.label(for: (.offline, nil), presences: Self.shown(.available, .available, .offline)) == "Offline · 2 Available")
    }

    @Test func `a status message replaces the status name`() {
        #expect(StatusSummary.label(for: (.away, "Lunch"), presences: Self.shown(.away, .offline)) == "Lunch · 1 Offline")
        #expect(StatusSummary.label(for: (.away, ""), presences: Self.shown(.away)) == "Away")
    }

    @Test(arguments: [
        (PresenceService.PresenceStatus.available, MenuStatusRow.Mark.mixed),
        (.offline, .mixed),
        (.away, .none)
    ])
    func `a status some accounts show is mixed`(status: PresenceService.PresenceStatus, expected: MenuStatusRow.Mark) {
        #expect(StatusSummary.mark(for: status, presences: Self.shown(.available, .offline)) == expected)
    }

    @Test func `a status every account shows is checked`() {
        #expect(StatusSummary.mark(for: .dnd, presences: Self.shown(.dnd, .dnd, .dnd)) == .checked)
    }

    @Test func `nothing is marked without accounts`() {
        #expect(StatusSummary.mark(for: .offline, presences: []) == .none)
    }

    @Test func `a saved message is checked only when every account shows that status and message`() {
        let presences: StatusSummary.Presences = [(.away, "Lunch"), (.away, "Lunch")]
        #expect(StatusSummary.mark(for: .away, message: "Lunch", presences: presences) == .checked)
    }

    @Test func `a saved message is mixed when an account shows the status without the message`() {
        let presences: StatusSummary.Presences = [(.away, "Lunch"), (.away, nil)]
        #expect(StatusSummary.mark(for: .away, message: "Lunch", presences: presences) == .mixed)
    }

    @Test func `a saved message is unmarked when no account shows it under that status`() {
        let presences: StatusSummary.Presences = [(.dnd, "Lunch"), (.offline, nil)]
        #expect(StatusSummary.mark(for: .away, message: "Lunch", presences: presences) == .none)
    }
}
