import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

struct ContactCaptionTests {
    @Test
    func `status wins when enabled and a status message is present`() {
        let caption = ContactCaption.resolve(
            statusMessage: "Lunch", presence: .available,
            showStatusMessages: true, isPendingSubscription: true, lastSeen: Date()
        )
        #expect(caption == .status("Lunch"))
        #expect(caption.hasSecondLine)
    }

    @Test
    func `status falls back to the presence display name when no message`() {
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: .available,
            showStatusMessages: true, isPendingSubscription: false, lastSeen: nil
        )
        #expect(caption == .status(PresenceService.PresenceStatus.available.displayName))
    }

    @Test
    func `status is suppressed when showStatusMessages is off`() {
        // With status off, an otherwise status-eligible contact falls through to
        // the next branch (here, pending) rather than showing a status line.
        let caption = ContactCaption.resolve(
            statusMessage: "Lunch", presence: .available,
            showStatusMessages: false, isPendingSubscription: true, lastSeen: nil
        )
        #expect(caption == .pendingApproval)
    }

    @Test
    func `pending shows when not status-eligible`() {
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: .available,
            showStatusMessages: false, isPendingSubscription: true, lastSeen: nil
        )
        #expect(caption == .pendingApproval)
    }

    @Test
    func `last-seen shows only when offline with a timestamp`() {
        let lastSeen = Date(timeIntervalSince1970: 1_000_000)
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: nil,
            showStatusMessages: true, isPendingSubscription: false, lastSeen: lastSeen
        )
        #expect(caption == .lastSeen(lastSeen))
    }

    @Test
    func `last-seen is suppressed when a presence is known`() {
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: .offline,
            showStatusMessages: false, isPendingSubscription: false, lastSeen: Date()
        )
        // `.offline` is a known presence (not nil), so the last-seen branch — which
        // requires `presence == nil` — does not fire.
        #expect(caption == .none)
        #expect(!caption.hasSecondLine)
    }

    @Test
    func `a disabled status does not leak past the gate to last-seen`() {
        // statusMessage is present but showStatusMessages is off: the status branch
        // must not fire, and resolution falls through to the last-seen branch.
        let lastSeen = Date(timeIntervalSince1970: 2_000_000)
        let caption = ContactCaption.resolve(
            statusMessage: "Lunch", presence: nil,
            showStatusMessages: false, isPendingSubscription: false, lastSeen: lastSeen
        )
        #expect(caption == .lastSeen(lastSeen))
    }

    @Test
    func `an empty status message still produces a status caption`() {
        // Documents current behavior: the status branch unwraps with `let`, not an
        // emptiness check, so an empty status string is treated as present.
        let caption = ContactCaption.resolve(
            statusMessage: "", presence: .available,
            showStatusMessages: true, isPendingSubscription: false, lastSeen: nil
        )
        #expect(caption == .status(""))
        #expect(caption.hasSecondLine)
    }

    @Test
    func `no caption when nothing applies`() {
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: .available,
            showStatusMessages: false, isPendingSubscription: false, lastSeen: nil
        )
        #expect(caption == .none)
        #expect(!caption.hasSecondLine)
    }
}
