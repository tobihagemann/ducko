import CryptoKit

/// Computes the SHA-1 hash of the given data and returns a lowercase hex string.
public func sha1Hex(_ data: [UInt8]) -> String {
    hexString(Insecure.SHA1.hash(data: data))
}

/// Renders bytes as a lowercase hex string.
func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes
        .map { byte in
            byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
        }
        .joined()
}
