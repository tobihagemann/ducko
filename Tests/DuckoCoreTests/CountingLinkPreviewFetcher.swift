import Foundation
@testable import DuckoCore

/// Non-blocking link-preview fetcher that counts invocations and returns a fixed preview, for asserting whether
/// a fetch fired.
actor CountingLinkPreviewFetcher: LinkPreviewFetcher {
    private(set) var invocationCount = 0

    func fetchPreview(for url: URL) async throws -> LinkPreview? {
        invocationCount += 1
        return LinkPreview(
            url: url.absoluteString,
            title: "Counted Title",
            descriptionText: "A description",
            siteName: "example.com",
            fetchedAt: Date()
        )
    }
}
