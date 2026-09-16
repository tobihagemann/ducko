import Foundation

extension URL {
    /// Whether this is a web address — the only kind of peer-supplied link that may reach an image loader, the browser
    /// or a download.
    var isWebAddress: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}
