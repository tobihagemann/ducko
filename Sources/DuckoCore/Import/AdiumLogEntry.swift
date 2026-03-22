import Foundation

/// A single parsed message from an Adium chat log.
package struct AdiumLogEntry {
    let sender: String
    let timestamp: Date
    let alias: String?
    let body: String
    let htmlBody: String?
    let isAutoreply: Bool

    init(
        sender: String,
        timestamp: Date,
        alias: String? = nil,
        body: String,
        htmlBody: String? = nil,
        isAutoreply: Bool = false
    ) {
        self.sender = sender
        self.timestamp = timestamp
        self.alias = alias
        self.body = body
        self.htmlBody = htmlBody
        self.isAutoreply = isAutoreply
    }
}
