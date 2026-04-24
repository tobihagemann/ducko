import Foundation
import Testing

/// Shape-invariant tests for `FixtureOMEMOIdentity`. A regression in any of the
/// five field checks would silently seed a corrupt identity and `OMEMOModule`
/// would then fail asynchronously, surfacing as an obscure integration-test
/// timeout rather than a clear fixture-format error.
enum OMEMOFixtureFormatTests {
    private static func validFixture(preKeys: [FixtureOMEMOIdentity.PreKey]? = nil) -> FixtureOMEMOIdentity {
        FixtureOMEMOIdentity(
            deviceID: 1,
            identityKeyRaw: Array(repeating: 0x11, count: 32),
            signedPreKeyID: 7,
            signedPreKeyRaw: Array(repeating: 0x22, count: 32),
            signedPreKeySignature: Array(repeating: 0x33, count: 64),
            preKeys: preKeys ?? [
                FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32))
            ]
        )
    }

    struct Invariants {
        @Test func `valid fixture passes invariants`() {
            #expect(OMEMOFixtureFormatTests.validFixture().passesShapeInvariants)
        }

        @Test func `empty preKeys fails`() {
            #expect(!OMEMOFixtureFormatTests.validFixture(preKeys: []).passesShapeInvariants)
        }

        @Test func `identityKeyRaw wrong length fails`() {
            let fixture = FixtureOMEMOIdentity(
                deviceID: 1,
                identityKeyRaw: Array(repeating: 0x11, count: 31),
                signedPreKeyID: 7,
                signedPreKeyRaw: Array(repeating: 0x22, count: 32),
                signedPreKeySignature: Array(repeating: 0x33, count: 64),
                preKeys: [
                    FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32))
                ]
            )
            #expect(!fixture.passesShapeInvariants)
        }

        @Test func `signedPreKeyRaw wrong length fails`() {
            let fixture = FixtureOMEMOIdentity(
                deviceID: 1,
                identityKeyRaw: Array(repeating: 0x11, count: 32),
                signedPreKeyID: 7,
                signedPreKeyRaw: Array(repeating: 0x22, count: 33),
                signedPreKeySignature: Array(repeating: 0x33, count: 64),
                preKeys: [
                    FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32))
                ]
            )
            #expect(!fixture.passesShapeInvariants)
        }

        @Test func `signedPreKeySignature wrong length fails`() {
            let fixture = FixtureOMEMOIdentity(
                deviceID: 1,
                identityKeyRaw: Array(repeating: 0x11, count: 32),
                signedPreKeyID: 7,
                signedPreKeyRaw: Array(repeating: 0x22, count: 32),
                signedPreKeySignature: Array(repeating: 0x33, count: 63),
                preKeys: [
                    FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32))
                ]
            )
            #expect(!fixture.passesShapeInvariants)
        }

        @Test func `preKey wrong length fails`() {
            let fixture = OMEMOFixtureFormatTests.validFixture(preKeys: [
                FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32)),
                FixtureOMEMOIdentity.PreKey(keyID: 2, keyRaw: Array(repeating: 0x55, count: 31))
            ])
            #expect(!fixture.passesShapeInvariants)
        }
    }

    struct CodableCases {
        @Test func `legacy fixture without isUsed decodes with isUsed defaulting to false`() throws {
            let json = """
            {
                "deviceID": 1,
                "identityKeyRaw": \(Array(repeating: 17, count: 32)),
                "signedPreKeyID": 7,
                "signedPreKeyRaw": \(Array(repeating: 34, count: 32)),
                "signedPreKeySignature": \(Array(repeating: 51, count: 64)),
                "preKeys": [
                    {"keyID": 1, "keyRaw": \(Array(repeating: 68, count: 32))}
                ]
            }
            """
            let data = try #require(json.data(using: .utf8))
            let decoded = try JSONDecoder().decode(FixtureOMEMOIdentity.self, from: data)
            #expect(decoded.preKeys.count == 1)
            #expect(decoded.preKeys[0].isUsed == false)
        }

        @Test func `fixture round-trips through JSON preserving isUsed`() throws {
            let fixture = OMEMOFixtureFormatTests.validFixture(preKeys: [
                FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32), isUsed: true),
                FixtureOMEMOIdentity.PreKey(keyID: 2, keyRaw: Array(repeating: 0x55, count: 32), isUsed: false)
            ])
            let encoded = try JSONEncoder().encode(fixture)
            let decoded = try JSONDecoder().decode(FixtureOMEMOIdentity.self, from: encoded)
            #expect(decoded.preKeys.map(\.isUsed) == [true, false])
        }
    }
}
