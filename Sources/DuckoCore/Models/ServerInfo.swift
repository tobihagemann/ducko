import Foundation

public struct ServerInfo: Sendable {
    public let contactAddresses: [ContactAddress]

    public init(contactAddresses: [ContactAddress]) {
        self.contactAddresses = contactAddresses
    }
}

public struct ContactAddress: Sendable, Identifiable {
    public var id: String {
        "\(type)-\(address)"
    }

    public let type: ContactAddressType
    public let address: String

    public init(type: ContactAddressType, address: String) {
        self.type = type
        self.address = address
    }
}

public enum ContactAddressType: String, Sendable, CaseIterable {
    case admin = "admin-addresses"
    case abuse = "abuse-addresses"
    case feedback = "feedback-addresses"
    case support = "support-addresses"
    case security = "security-addresses"
    case sales = "sales-addresses"

    public var displayName: String {
        switch self {
        case .admin: "Admin"
        case .abuse: "Abuse"
        case .feedback: "Feedback"
        case .support: "Support"
        case .security: "Security"
        case .sales: "Sales"
        }
    }
}
