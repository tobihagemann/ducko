import Testing
@testable import DuckoCore

enum OMEMOTrustTests {
    struct TrustLevelTests {
        @Test(arguments: [
            (OMEMOTrustLevel.verified, false, true),
            (OMEMOTrustLevel.verified, true, true),
            (OMEMOTrustLevel.trusted, false, true),
            (OMEMOTrustLevel.trusted, true, true),
            (OMEMOTrustLevel.undecided, false, false),
            (OMEMOTrustLevel.undecided, true, true),
            (OMEMOTrustLevel.untrusted, false, false),
            (OMEMOTrustLevel.untrusted, true, false)
        ])
        func `is trusted for encryption with TOFU`(
            level: OMEMOTrustLevel, tofu: Bool, expected: Bool
        ) {
            let result = level.isTrustedForEncryption(trustOnFirstUse: tofu)
            #expect(result == expected)
        }

        @Test func `strict trust property`() {
            #expect(OMEMOTrustLevel.verified.isTrustedForEncryption)
            #expect(OMEMOTrustLevel.trusted.isTrustedForEncryption)
            #expect(!OMEMOTrustLevel.undecided.isTrustedForEncryption)
            #expect(!OMEMOTrustLevel.untrusted.isTrustedForEncryption)
        }
    }

    struct DeviceInfoTests {
        @Test func identifiable() {
            let info = OMEMODeviceInfo(
                peerJID: "alice@example.com",
                deviceID: 42,
                fingerprint: "abcd1234",
                trustLevel: .trusted
            )
            #expect(info.id == "alice@example.com-42")
        }
    }
}
