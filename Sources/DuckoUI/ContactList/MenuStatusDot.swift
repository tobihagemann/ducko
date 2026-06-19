import AppKit
import DuckoCore
import SwiftUI

/// A colored status dot for use inside SwiftUI `Menu`s. Menus render only `Text` and `Image`, and they tint
/// template images (including SF Symbols) to the label color — so a `Circle` shape is dropped and a
/// `circle.fill` symbol comes out monochrome. Baking the color into a non-template `NSImage` is the only way
/// the actual color survives into the menu. Matches `PresenceIndicator`'s color map.
struct MenuStatusDot: View {
    let status: PresenceService.PresenceStatus

    var body: some View {
        Image(nsImage: Self.dot(for: status))
    }

    private static func color(for status: PresenceService.PresenceStatus) -> NSColor {
        switch status {
        case .available: .systemGreen
        case .away, .xa: .systemYellow
        case .dnd: .systemRed
        case .offline: .systemGray
        }
    }

    private static func dot(for status: PresenceService.PresenceStatus) -> NSImage {
        let color = color(for: status)
        // `drawingHandler` re-runs per target resolution (correct on Retina) and avoids the deprecated
        // `lockFocus`/`unlockFocus` pair.
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
