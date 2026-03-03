import Foundation
import Testing
@testable import DuckoCore

enum LinkPreviewServiceTests {
    struct CachedPreview {
        @Test
        func `Returns nil for uncached URL`() {
            let store = MockPersistenceStore()
            let service = LinkPreviewService(fetcher: NoOpLinkPreviewFetcher(), store: store)

            let result = service.cachedPreview(for: "https://example.com")
            #expect(result == nil)
        }

        @Test
        func `Returns cached preview after fetch`() async throws {
            let store = MockPersistenceStore()
            let fetcher = StubLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: store)

            let url = try #require(URL(string: "https://example.com"))
            _ = try await service.fetchPreview(for: url)

            let result = service.cachedPreview(for: "https://example.com")
            #expect(result != nil)
            #expect(result?.title == "Stub Title")
        }
    }
}

// MARK: - Test Helpers

private struct StubLinkPreviewFetcher: LinkPreviewFetcher {
    func fetchPreview(for url: URL) async throws -> LinkPreview? {
        LinkPreview(
            url: url.absoluteString,
            title: "Stub Title",
            descriptionText: "A description",
            siteName: "example.com",
            fetchedAt: Date()
        )
    }
}
