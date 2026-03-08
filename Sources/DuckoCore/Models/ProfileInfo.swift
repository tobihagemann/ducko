import Foundation

/// DuckoCore-level representation of a vCard profile, consumable by DuckoUI without importing DuckoXMPP.
public struct ProfileInfo: Sendable {
    // MARK: - Name Fields

    public var fullName: String?
    public var nickname: String?
    public var familyName: String?
    public var givenName: String?
    public var middleName: String?
    public var namePrefix: String?
    public var nameSuffix: String?

    // MARK: - Contact Fields

    public var emails: [EmailEntry]
    public var telephones: [TelephoneEntry]
    public var addresses: [AddressEntry]

    // MARK: - Organization Fields

    public var organization: String?
    public var title: String?
    public var role: String?

    // MARK: - Other Fields

    public var url: String?
    public var birthday: String?
    public var note: String?

    // MARK: - Photo

    public var photoData: Data?
    public var photoType: String?

    // MARK: - Nested Types

    public enum EntryType: String, Sendable {
        case home, work
    }

    public struct EmailEntry: Sendable, Identifiable {
        public let id: UUID
        public var address: String
        public var types: [EntryType]

        public init(id: UUID = UUID(), address: String = "", types: [EntryType] = []) {
            self.id = id
            self.address = address
            self.types = types
        }
    }

    public struct TelephoneEntry: Sendable, Identifiable {
        public let id: UUID
        public var number: String
        public var types: [EntryType]

        public init(id: UUID = UUID(), number: String = "", types: [EntryType] = []) {
            self.id = id
            self.number = number
            self.types = types
        }
    }

    public struct AddressEntry: Sendable, Identifiable {
        public let id: UUID
        public var street: String?
        public var locality: String?
        public var region: String?
        public var postalCode: String?
        public var country: String?
        public var types: [EntryType]

        public init(
            id: UUID = UUID(),
            street: String? = nil,
            locality: String? = nil,
            region: String? = nil,
            postalCode: String? = nil,
            country: String? = nil,
            types: [EntryType] = []
        ) {
            self.id = id
            self.street = street
            self.locality = locality
            self.region = region
            self.postalCode = postalCode
            self.country = country
            self.types = types
        }
    }

    // MARK: - Init

    public init(
        fullName: String? = nil,
        nickname: String? = nil,
        familyName: String? = nil,
        givenName: String? = nil,
        middleName: String? = nil,
        namePrefix: String? = nil,
        nameSuffix: String? = nil,
        emails: [EmailEntry] = [],
        telephones: [TelephoneEntry] = [],
        addresses: [AddressEntry] = [],
        organization: String? = nil,
        title: String? = nil,
        role: String? = nil,
        url: String? = nil,
        birthday: String? = nil,
        note: String? = nil,
        photoData: Data? = nil,
        photoType: String? = nil
    ) {
        self.fullName = fullName
        self.nickname = nickname
        self.familyName = familyName
        self.givenName = givenName
        self.middleName = middleName
        self.namePrefix = namePrefix
        self.nameSuffix = nameSuffix
        self.emails = emails
        self.telephones = telephones
        self.addresses = addresses
        self.organization = organization
        self.title = title
        self.role = role
        self.url = url
        self.birthday = birthday
        self.note = note
        self.photoData = photoData
        self.photoType = photoType
    }
}
