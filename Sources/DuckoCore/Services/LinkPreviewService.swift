import Foundation

public final class LinkPreviewService: Sendable {
    private let fetcher: any LinkPreviewFetcher
    private let store: any PersistenceStore

    public init(fetcher: any LinkPreviewFetcher, store: any PersistenceStore) {
        self.fetcher = fetcher
        self.store = store
    }

    public func fetchPreview(for url: URL) async throws -> LinkPreview? {
        // Check store cache first, then fetch via fetcher and persist result.
        // Stub — cache lookup will be added when PersistenceStore gains LinkPreview queries.
        try await fetcher.fetchPreview(for: url)
    }
}
