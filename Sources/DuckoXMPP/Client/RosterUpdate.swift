public struct RosterUpdate: Sendable {
    public enum Origin: Equatable, Sendable {
        case initial
        case push
        case readback(String)
    }

    public enum Contents: Sendable {
        case snapshot([RosterItem])
        case delta(RosterItem)
        case cachedBaseline
        case initialQueryFailed
    }

    public let receipt: UInt64
    public let origin: Origin
    public let contents: Contents
    public let version: String?

    public init(receipt: UInt64, origin: Origin, contents: Contents, version: String? = nil) {
        self.receipt = receipt
        self.origin = origin
        self.contents = contents
        self.version = version
    }

    public var isInitialResponse: Bool {
        guard origin == .initial else { return false }
        return switch contents {
        case .snapshot, .cachedBaseline: true
        case .delta, .initialQueryFailed: false
        }
    }
}
