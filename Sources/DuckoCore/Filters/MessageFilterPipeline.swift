import DuckoXMPP
import Foundation

public struct MessageContent: Sendable {
    public var body: String
    public var htmlBody: String?
    public var detectedURLs: [URL]

    public init(body: String, htmlBody: String? = nil, detectedURLs: [URL] = []) {
        self.body = body
        self.htmlBody = htmlBody
        self.detectedURLs = detectedURLs
    }
}

public enum FilterDirection: Sendable {
    case incoming, outgoing
}

public struct FilterContext: Sendable {
    public let conversationJID: BareJID
    public let accountJID: BareJID

    public init(conversationJID: BareJID, accountJID: BareJID) {
        self.conversationJID = conversationJID
        self.accountJID = accountJID
    }
}

public protocol MessageFilter: Sendable {
    var priority: Int { get }
    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent
}

public actor MessageFilterPipeline {
    private var filters: [any MessageFilter] = []

    public init() {}

    public func register(_ filter: any MessageFilter) {
        filters.append(filter)
        filters.sort { $0.priority < $1.priority }
    }

    public func process(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        var result = content
        for filter in filters {
            result = await filter.filter(result, direction: direction, context: context)
        }
        return result
    }
}
