import CryptoKit

/// Hash algorithms supported by XEP-0390 Entity Capabilities 2.0.
enum Caps2HashAlgorithm: String, CaseIterable {
    case sha256 = "sha-256"
    case sha512 = "sha-512"

    func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .sha256: Array(SHA256.hash(data: data))
        case .sha512: Array(SHA512.hash(data: data))
        }
    }
}

/// XEP-0390 capability hash input generation.
///
/// Uses ASCII control characters as delimiters per XEP-0390 §5.2:
/// - `0x1f` (Unit Separator): terminates individual attribute values
/// - `0x1e` (Record Separator): terminates complete identities
/// - `0x1c` (File Separator): terminates each major section
enum Caps2Hash {
    /// Generates the XEP-0390 capability hash input bytes.
    static func generateHashInput(
        identities: [ServiceDiscoveryModule.Identity],
        features: Set<String>
    ) -> [UInt8] {
        var result: [UInt8] = []

        // Features section: sort by i;octet (byte-wise), each terminated by 0x1f
        let sortedFeatures = features.sorted()
        for feature in sortedFeatures {
            result.append(contentsOf: Array(feature.utf8))
            result.append(0x1F)
        }
        result.append(0x1C)

        // Identities section: encode each as category 0x1f type 0x1f lang 0x1f name 0x1f 0x1e
        // Sort the concatenated identity byte strings by i;octet
        let identityBytes: [[UInt8]] = identities.map { identity in
            var bytes: [UInt8] = []
            bytes.append(contentsOf: Array(identity.category.utf8))
            bytes.append(0x1F)
            bytes.append(contentsOf: Array(identity.type.utf8))
            bytes.append(0x1F)
            // xml:lang — empty string for now (Ducko doesn't advertise a language)
            bytes.append(0x1F)
            bytes.append(contentsOf: Array((identity.name ?? "").utf8))
            bytes.append(0x1F)
            bytes.append(0x1E)
            return bytes
        }
        for bytes in identityBytes.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            result.append(contentsOf: bytes)
        }
        result.append(0x1C)

        // Extensions section: empty for now (Ducko doesn't include data forms in disco#info)
        result.append(0x1C)

        return result
    }
}
