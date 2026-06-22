import Foundation
import Testing
@testable import DuckoCore

struct ContactListResizeTests {
    // MARK: - topLeftAnchoredFrame

    @Test func `topLeftAnchoredFrame keeps the top edge fixed and grows down`() {
        let current = CGRect(x: 100, y: 200, width: 280, height: 320)
        let frame = ContactListResize.topLeftAnchoredFrame(current: current, targetSize: CGSize(width: 280, height: 400))
        // Top edge (maxY) stays at 520; the window grows downward by lowering origin.y.
        let expectedOriginY: CGFloat = 520 - 400
        #expect(frame.maxY == current.maxY)
        #expect(frame.origin.y == expectedOriginY)
        #expect(frame.height == 400)
    }

    @Test func `topLeftAnchoredFrame grows width to the right with origin x fixed`() {
        let current = CGRect(x: 100, y: 200, width: 280, height: 320)
        let frame = ContactListResize.topLeftAnchoredFrame(current: current, targetSize: CGSize(width: 360, height: 320))
        #expect(frame.origin.x == 100)
        #expect(frame.width == 360)
        // A pure width change leaves the vertical position untouched.
        #expect(frame.origin.y == current.origin.y)
        #expect(frame.maxY == current.maxY)
    }

    @Test func `topLeftAnchoredFrame shrinking keeps the top-left corner`() {
        let current = CGRect(x: 100, y: 200, width: 280, height: 320)
        let frame = ContactListResize.topLeftAnchoredFrame(current: current, targetSize: CGSize(width: 200, height: 120))
        let expectedOriginY: CGFloat = 520 - 120
        #expect(frame.origin.x == 100)
        #expect(frame.maxY == current.maxY)
        #expect(frame.origin.y == expectedOriginY)
    }

    // MARK: - height clamping (composed with ContactListSizing.fittedHeight)

    @Test func `a clamped target height caps the frame at the screen maximum`() {
        // A roster taller than the cap clamps to the cap before anchoring.
        let clamped = ContactListSizing.fittedHeight(measuredHeight: 900, fallbackHeight: 0, maxHeight: 600)
        let current = CGRect(x: 0, y: 0, width: 280, height: 320)
        let frame = ContactListResize.topLeftAnchoredFrame(current: current, targetSize: CGSize(width: 280, height: clamped))
        #expect(frame.height == 600)
    }

    // MARK: - pixelRounded

    @Test func `pixelRounded snaps to the backing-scale grid`() {
        let rounded = ContactListResize.pixelRounded(CGSize(width: 199.6, height: 320.4), scale: 2)
        #expect(rounded.width == 199.5)
        #expect(rounded.height == 320.5)
    }

    @Test func `pixelRounded falls back to whole points for a non-positive scale`() {
        let rounded = ContactListResize.pixelRounded(CGSize(width: 199.6, height: 320.4), scale: 0)
        #expect(rounded.width == 200)
        #expect(rounded.height == 320)
    }

    // MARK: - LayoutKey

    @Test func `LayoutKey equates identical rows and rounded size so the pass bails`() {
        let a = ContactListResize.LayoutKey(rowIDs: ["a", "b"], contentSize: CGSize(width: 280, height: 320), scale: 2)
        let b = ContactListResize.LayoutKey(rowIDs: ["a", "b"], contentSize: CGSize(width: 280, height: 320), scale: 2)
        #expect(a == b)
    }

    @Test func `LayoutKey rounds sub-pixel size jitter to equal`() {
        let a = ContactListResize.LayoutKey(rowIDs: ["a"], contentSize: CGSize(width: 280.1, height: 320.2), scale: 2)
        let b = ContactListResize.LayoutKey(rowIDs: ["a"], contentSize: CGSize(width: 280.0, height: 320.0), scale: 2)
        // Both round to the same backing-scale grid point, so the guard bails.
        #expect(a == b)
    }

    @Test func `LayoutKey differs when a row id changes`() {
        let a = ContactListResize.LayoutKey(rowIDs: ["a", "b"], contentSize: CGSize(width: 280, height: 320), scale: 2)
        let b = ContactListResize.LayoutKey(rowIDs: ["a", "c"], contentSize: CGSize(width: 280, height: 320), scale: 2)
        #expect(a != b)
    }

    @Test func `LayoutKey differs on a chrome-only height change with identical rows`() {
        let a = ContactListResize.LayoutKey(rowIDs: ["a", "b"], contentSize: CGSize(width: 280, height: 320), scale: 2)
        let b = ContactListResize.LayoutKey(rowIDs: ["a", "b"], contentSize: CGSize(width: 280, height: 360), scale: 2)
        #expect(a != b)
    }

    @Test func `LayoutKey keeps account-qualified ids distinct`() {
        // A same-JID peer on two accounts produces two distinct row ids, so the
        // guard never collapses them into one.
        let a = ContactListResize.LayoutKey(
            rowIDs: ["Friends|bob@example.com|account-1"],
            contentSize: CGSize(width: 280, height: 320),
            scale: 2
        )
        let b = ContactListResize.LayoutKey(
            rowIDs: ["Friends|bob@example.com|account-2"],
            contentSize: CGSize(width: 280, height: 320),
            scale: 2
        )
        #expect(a != b)
    }
}
