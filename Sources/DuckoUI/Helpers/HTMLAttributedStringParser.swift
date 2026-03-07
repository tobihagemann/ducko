import Foundation

enum HTMLAttributedStringParser {
    static func parse(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        guard let nsAttr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        var attributed = AttributedString(nsAttr)
        attributed.font = nil
        attributed.foregroundColor = nil
        return attributed
    }
}
