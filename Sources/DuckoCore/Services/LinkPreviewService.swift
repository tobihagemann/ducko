import Foundation
import os

private let log = Logger(subsystem: "com.ducko.core", category: "linkPreview")

public final class LinkPreviewService: Sendable {
    private let fetcher: any LinkPreviewFetcher
    private let store: any PersistenceStore
    private let cache: OSAllocatedUnfairLock<[String: LinkPreview]>

    public init(fetcher: any LinkPreviewFetcher, store: any PersistenceStore) {
        self.fetcher = fetcher
        self.store = store
        self.cache = OSAllocatedUnfairLock(initialState: [:])
    }

    public func fetchPreview(for url: URL) async throws -> LinkPreview? {
        let key = url.absoluteString

        // Check in-memory cache
        if let cached = cache.withLock({ $0[key] }) {
            return cached
        }

        // Check persistence store
        if let persisted = try await store.fetchLinkPreview(for: key) {
            cache.withLock { $0[key] = persisted }
            return persisted
        }

        // Fetch via fetcher
        guard let preview = try await fetcher.fetchPreview(for: url) else {
            return nil
        }

        // Persist and cache
        do {
            try await store.upsertLinkPreview(preview)
        } catch {
            log.warning("Failed to persist link preview: \(error)")
        }
        cache.withLock { $0[key] = preview }

        return preview
    }
}
