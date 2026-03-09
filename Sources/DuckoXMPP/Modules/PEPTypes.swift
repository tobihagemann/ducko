/// A single PubSub item from a PEP notification or retrieval (XEP-0163).
public struct PEPItem: Sendable {
    public let id: String
    public let payload: XMLElement

    public init(id: String, payload: XMLElement) {
        self.id = id
        self.payload = payload
    }
}
