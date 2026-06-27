import AppKit
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct ContactListResizeGateTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: true
        )
    }

    @Test func `windowWillResize pins the width when only width is locked`() {
        let gate = ContactListResizeGate()
        gate.lockWidth = true
        let window = makeWindow()
        let result = gate.windowWillResize(window, to: NSSize(width: 500, height: 600))
        #expect(result.width == window.frame.width)
        #expect(result.height == 600)
    }

    @Test func `windowWillResize pins the height when only height is locked`() {
        let gate = ContactListResizeGate()
        gate.lockHeight = true
        let window = makeWindow()
        let result = gate.windowWillResize(window, to: NSSize(width: 500, height: 600))
        #expect(result.width == 500)
        #expect(result.height == window.frame.height)
    }

    @Test func `windowWillResize pins both axes when both are locked`() {
        let gate = ContactListResizeGate()
        gate.lockWidth = true
        gate.lockHeight = true
        let window = makeWindow()
        let result = gate.windowWillResize(window, to: NSSize(width: 500, height: 600))
        #expect(result.width == window.frame.width)
        #expect(result.height == window.frame.height)
    }

    @Test func `windowWillResize passes a proposed size through when programmatic resize is allowed`() {
        let gate = ContactListResizeGate()
        gate.lockWidth = true
        gate.lockHeight = true
        gate.allowProgrammaticResize = true
        let window = makeWindow()
        let proposed = NSSize(width: 500, height: 600)
        #expect(gate.windowWillResize(window, to: proposed) == proposed)
    }

    @Test func `windowDidUpdate removes resizable only when both axes are locked`() {
        let gate = ContactListResizeGate()
        gate.lockWidth = true
        gate.lockHeight = true
        let window = makeWindow()
        #expect(window.styleMask.contains(.resizable))
        gate.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification, object: window))
        #expect(!window.styleMask.contains(.resizable))
    }

    @Test func `windowDidUpdate keeps resizable when only one axis is locked`() {
        let gate = ContactListResizeGate()
        gate.lockWidth = true
        let window = makeWindow()
        gate.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification, object: window))
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func `windowDidUpdate restores resizable when neither axis is locked`() {
        let gate = ContactListResizeGate()
        let window = makeWindow()
        window.styleMask.remove(.resizable)
        gate.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification, object: window))
        #expect(window.styleMask.contains(.resizable))
    }
}
