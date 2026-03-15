public struct OMEMODeviceInfo: Sendable, Identifiable {
    public var id: String {
        "\(peerJID)-\(deviceID)"
    }

    public let peerJID: String
    public let deviceID: UInt32
    public let fingerprint: String
    public let trustLevel: OMEMOTrustLevel

    public init(peerJID: String, deviceID: UInt32, fingerprint: String, trustLevel: OMEMOTrustLevel) {
        self.peerJID = peerJID
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.trustLevel = trustLevel
    }

    /// Formats a hex fingerprint with spaces every 8 characters for readability.
    public static func formatFingerprint(_ hex: String) -> String {
        var result = ""
        for (index, char) in hex.enumerated() {
            if index > 0, index.isMultiple(of: 8) {
                result += " "
            }
            result.append(char)
        }
        return result
    }
}
