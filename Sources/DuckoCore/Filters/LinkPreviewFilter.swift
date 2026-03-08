import os

private let log = Logger(subsystem: "com.ducko.core", category: "linkPreviewFilter")

/// Triggers async link preview fetching for detected URLs in incoming messages.
/// Does not block the filter pipeline — previews are fetched in the background.
struct LinkPreviewFilter: MessageFilter {
    let priority = 200
    private let previewService: LinkPreviewService

    init(previewService: LinkPreviewService) {
        self.previewService = previewService
    }

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        guard direction == .incoming, !content.detectedURLs.isEmpty else { return content }

        let service = previewService
        for url in content.detectedURLs {
            Task.detached {
                do {
                    _ = try await service.fetchPreview(for: url)
                } catch {
                    log.debug("Link preview fetch failed for \(url): \(error)")
                }
            }
        }

        return content
    }
}
