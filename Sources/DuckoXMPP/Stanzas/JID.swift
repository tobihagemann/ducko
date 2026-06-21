/// A bare JID: `localPart@domainPart` or just `domainPart`.
public struct BareJID: Hashable, Sendable {
    public let localPart: String?
    public let domainPart: String

    public init?(localPart: String?, domainPart: String) {
        guard !domainPart.isEmpty else { return nil }
        if let localPart, localPart.isEmpty { return nil }
        // RFC 7622 §3.3.1: localpart is PRECIS UsernameCaseMapped (width map, validate, lowercase,
        // NFC, Bidi) plus the XMPP-specific excluded characters.
        if let localPart {
            guard let normalized = PRECIS.usernameCaseMapped(localPart),
                  !Self.containsExcludedLocalpartCharacter(normalized) else { return nil }
            self.localPart = normalized
        } else {
            self.localPart = nil
        }
        // RFC 7622 §3.2.1: domainpart is IDNA2008, stored as the U-label canonical form.
        guard let normalizedDomain = IDNA.toUnicode(domainPart) else { return nil }
        self.domainPart = normalizedDomain
    }

    /// RFC 7622 §3.3.1 excludes these from the localpart. They are printable ASCII (PVALID under
    /// PRECIS ASCII7), so this explicit check — not the PRECIS pass — is what rejects them.
    private static func containsExcludedLocalpartCharacter(_ localPart: String) -> Bool {
        localPart.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x22, 0x26, 0x27, 0x2F, 0x3A, 0x3C, 0x3E, 0x40: // " & ' / : < > @
                return true
            default:
                return false
            }
        }
    }
}

extension BareJID: CustomStringConvertible {
    public var description: String {
        if let localPart {
            return "\(localPart)@\(domainPart)"
        }
        return domainPart
    }
}

extension BareJID: Codable {
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let jid = Self.parse(string) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid bare JID: \(string)")
            )
        }
        self = jid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public extension BareJID {
    /// Parses a bare JID string. Returns `nil` if the string contains a resource part or is otherwise invalid.
    static func parse(_ string: String) -> BareJID? {
        guard !string.isEmpty else { return nil }
        // Bare JIDs must not contain a resource separator
        guard !string.contains("/") else { return nil }

        if let atIndex = string.firstIndex(of: "@") {
            let localPart = String(string[..<atIndex])
            let domainPart = String(string[string.index(after: atIndex)...])
            return BareJID(localPart: localPart, domainPart: domainPart)
        } else {
            return BareJID(localPart: nil, domainPart: string)
        }
    }
}

// MARK: - FullJID

/// A full JID: `localPart@domainPart/resourcePart`.
public struct FullJID: Hashable, Sendable {
    public let bareJID: BareJID
    public let resourcePart: String

    public init?(bareJID: BareJID, resourcePart: String) {
        guard !resourcePart.isEmpty else { return nil }
        // RFC 7622 §3.4.1: resourcepart is PRECIS OpaqueString (non-ASCII spaces → U+0020, NFC,
        // case preserved).
        guard let normalized = PRECIS.opaqueString(resourcePart) else { return nil }
        self.bareJID = bareJID
        self.resourcePart = normalized
    }
}

extension FullJID: CustomStringConvertible {
    public var description: String {
        "\(bareJID)/\(resourcePart)"
    }
}

extension FullJID: Codable {
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let jid = Self.parse(string) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid full JID: \(string)")
            )
        }
        self = jid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public extension FullJID {
    /// Normalizes a resourcepart (e.g. a MUC occupant nickname) via PRECIS OpaqueString, matching
    /// what `FullJID.init?` applies.
    static func normalizeResourcePart(_ resourcePart: String) -> String? {
        PRECIS.opaqueString(resourcePart)
    }

    /// Parses a full JID string. The resource may contain slashes per RFC 6120.
    static func parse(_ string: String) -> FullJID? {
        guard !string.isEmpty else { return nil }
        // Split on first `/` — resource part may contain additional slashes
        guard let slashIndex = string.firstIndex(of: "/") else { return nil }

        let barePart = String(string[..<slashIndex])
        let resourcePart = String(string[string.index(after: slashIndex)...])

        guard let bareJID = BareJID.parse(barePart) else { return nil }
        return FullJID(bareJID: bareJID, resourcePart: resourcePart)
    }
}

// MARK: - JID

/// A JID that is either bare or full.
public enum JID: Hashable, Sendable {
    case bare(BareJID)
    case full(FullJID)

    public var bareJID: BareJID {
        switch self {
        case let .bare(bareJID): bareJID
        case let .full(fullJID): fullJID.bareJID
        }
    }
}

extension JID: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .bare(bareJID): bareJID.description
        case let .full(fullJID): fullJID.description
        }
    }
}

extension JID: Codable {
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let jid = Self.parse(string) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid JID: \(string)")
            )
        }
        self = jid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public extension JID {
    /// Parses a JID string, returning `.full` if a resource is present, `.bare` otherwise.
    static func parse(_ string: String) -> JID? {
        if let fullJID = FullJID.parse(string) {
            return .full(fullJID)
        }
        if let bareJID = BareJID.parse(string) {
            return .bare(bareJID)
        }
        return nil
    }
}
