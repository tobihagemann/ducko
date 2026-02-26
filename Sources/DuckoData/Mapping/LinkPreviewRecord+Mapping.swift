import DuckoCore
import Foundation

extension LinkPreviewRecord {
    func toDomain() -> LinkPreview {
        LinkPreview(
            url: url,
            title: title,
            descriptionText: descriptionText,
            imageURL: imageURL,
            siteName: siteName,
            fetchedAt: fetchedAt
        )
    }

    func update(from preview: LinkPreview) {
        title = preview.title
        descriptionText = preview.descriptionText
        imageURL = preview.imageURL
        siteName = preview.siteName
        fetchedAt = preview.fetchedAt
    }
}
