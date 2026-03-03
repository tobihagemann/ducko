import DuckoCore
import Foundation
import LinkPresentation

/// Extracted metadata values that are Sendable (unlike LPLinkMetadata itself).
private struct ExtractedMetadata: Sendable {
    let title: String?
    let siteName: String?
}

struct LPLinkPreviewFetcher: LinkPreviewFetcher {
    func fetchPreview(for url: URL) async throws -> LinkPreview? {
        let extracted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExtractedMetadata, Error>) in
            let provider = LPMetadataProvider()
            provider.startFetchingMetadata(for: url) { metadata, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let metadata {
                    let result = ExtractedMetadata(
                        title: metadata.title,
                        siteName: metadata.url?.host()
                    )
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
        }

        return LinkPreview(
            url: url.absoluteString,
            title: extracted.title,
            descriptionText: nil,
            imageURL: nil,
            siteName: extracted.siteName,
            fetchedAt: Date()
        )
    }
}
