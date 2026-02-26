import Foundation

public protocol LinkPreviewFetcher: Sendable {
    func fetchPreview(for url: URL) async throws -> LinkPreview?
}

/// No-op implementation for CLI and testing.
public struct NoOpLinkPreviewFetcher: LinkPreviewFetcher {
    public init() {}

    public func fetchPreview(for url: URL) async throws -> LinkPreview? {
        nil
    }
}
