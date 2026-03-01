/// MAM (XEP-0313) query completion indicator.
public struct MAMFin: Sendable {
    public let complete: Bool
    public let first: String?
    public let last: String?
    public let count: Int?

    public init(complete: Bool, first: String?, last: String?, count: Int?) {
        self.complete = complete
        self.first = first
        self.last = last
        self.count = count
    }

    // MARK: - Parsing

    /// Parses a `<fin xmlns="urn:xmpp:mam:2">` element.
    public static func parse(_ element: XMLElement) -> MAMFin? {
        guard element.name == "fin",
              element.namespace == XMPPNamespaces.mam else {
            return nil
        }

        let complete = element.attribute("complete") == "true"
        let rsm = element.child(named: "set", namespace: XMPPNamespaces.rsm)
        let first = rsm?.childText(named: "first")
        let last = rsm?.childText(named: "last")
        let count = rsm?.childText(named: "count").flatMap(Int.init)

        return MAMFin(complete: complete, first: first, last: last, count: count)
    }
}
