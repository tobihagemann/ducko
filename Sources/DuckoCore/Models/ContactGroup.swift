public struct ContactGroup: Sendable, Identifiable {
    public static let ungroupedName = "Ungrouped"

    public var id: String
    public var name: String
    public var contacts: [Contact]

    public init(id: String, name: String, contacts: [Contact]) {
        self.id = id
        self.name = name
        self.contacts = contacts
    }
}
