import Foundation

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

    public static func grouping(_ contacts: [Contact]) -> [ContactGroup] {
        var grouped: [String: [Contact]] = [:]
        for contact in contacts {
            for name in contact.groups.isEmpty ? [ungroupedName] : contact.groups {
                grouped[name, default: []].append(contact)
            }
        }
        let names = grouped.keys.sorted { lhs, rhs in
            if lhs == ungroupedName { return false }
            if rhs == ungroupedName { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return names.map { name in
            ContactGroup(id: name, name: name, contacts: (grouped[name] ?? []).sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            })
        }
    }
}
