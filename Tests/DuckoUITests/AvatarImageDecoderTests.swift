import AppKit
import Foundation
import Testing
@testable import DuckoUI

struct AvatarImageDecoderTests {
    /// A minimal valid 1×1 PNG.
    private static let validPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    @Test func `decode rejects payloads over the byte cap`() {
        let oversized = Data(count: AvatarImageDecoder.maxBytes + 1)
        #expect(AvatarImageDecoder.decode(oversized, maxPixelSize: 64) == nil)
    }

    @Test func `decode returns nil for undecodable data`() {
        #expect(AvatarImageDecoder.decode(Data([0, 1, 2, 3]), maxPixelSize: 64) == nil)
    }

    @Test func `decode returns nil for empty data`() {
        #expect(AvatarImageDecoder.decode(Data(), maxPixelSize: 64) == nil)
    }

    @Test func `decode produces a bounded image for valid PNG data`() throws {
        let png = try #require(Data(base64Encoded: Self.validPNGBase64))
        let image = try #require(AvatarImageDecoder.decode(png, maxPixelSize: 64))
        #expect(image.size.width > 0)
        #expect(image.size.width <= 64)
        #expect(image.size.height <= 64)
    }
}
