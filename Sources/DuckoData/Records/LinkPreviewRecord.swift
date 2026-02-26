import Foundation
import SwiftData

@Model
final class LinkPreviewRecord {
    @Attribute(.unique) var url: String
    var title: String?
    var descriptionText: String?
    var imageURL: String?
    var siteName: String?
    var fetchedAt: Date

    init(
        url: String,
        title: String? = nil,
        descriptionText: String? = nil,
        imageURL: String? = nil,
        siteName: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.url = url
        self.title = title
        self.descriptionText = descriptionText
        self.imageURL = imageURL
        self.siteName = siteName
        self.fetchedAt = fetchedAt
    }
}
