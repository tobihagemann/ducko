import AppKit
import DuckoCore
import Foundation
import ImageIO

/// Bounded decode for avatar image data, extracted from `AvatarView` so the
/// byte-cap and decode-failure paths are unit-testable. Image bytes arrive from
/// peer vCard photos and PEP avatars and are therefore untrusted: oversized or
/// decompression-heavy payloads must not hang the decode or exhaust memory.
enum AvatarImageDecoder {
    static let maxBytes = AvatarLimits.maxBytes

    /// Decode `data` at a bounded pixel size, returning `nil` for payloads over
    /// `maxBytes` or data that can't be decoded. Uses ImageIO's thumbnail path so
    /// the retained result is bounded to `maxPixelSize` rather than the source's
    /// full resolution.
    static func decode(_ data: Data, maxPixelSize: Int) -> NSImage? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
