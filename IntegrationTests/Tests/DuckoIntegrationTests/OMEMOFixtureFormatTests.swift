import DuckoCore
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

        @Test func `legacy fixture without accountJID decodes with accountJID nil`() throws {
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
            #expect(decoded.accountJID == nil)
        }

        @Test func `fixture round-trips accountJID`() throws {
            let fixture = FixtureOMEMOIdentity(
                deviceID: 1,
                identityKeyRaw: Array(repeating: 0x11, count: 32),
                signedPreKeyID: 7,
                signedPreKeyRaw: Array(repeating: 0x22, count: 32),
                signedPreKeySignature: Array(repeating: 0x33, count: 64),
                preKeys: [
                    FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32))
                ],
                accountJID: "alice@example.com"
            )
            let encoded = try JSONEncoder().encode(fixture)
            let decoded = try JSONDecoder().decode(FixtureOMEMOIdentity.self, from: encoded)
            #expect(decoded.accountJID == "alice@example.com")
        }
    }

    /// Locks the JID-mismatch refusal contract that protects against silent
    /// identity reuse across recycled fixture files.
    struct JIDMatchGate {
        @Test func `legacy fixture (no accountJID) is allowed`() {
            #expect(TestHarness.fixtureJIDMatchesCredential(nil, credentialJID: "alice@example.com"))
        }

        @Test func `same JID matches`() {
            #expect(TestHarness.fixtureJIDMatchesCredential("alice@example.com", credentialJID: "alice@example.com"))
        }

        @Test func `different JID is refused`() {
            #expect(!TestHarness.fixtureJIDMatchesCredential("alice@example.com", credentialJID: "bob@example.com"))
        }

        @Test func `case-different localpart matches via BareJID normalization`() {
            #expect(TestHarness.fixtureJIDMatchesCredential("Alice@example.com", credentialJID: "alice@example.com"))
        }
    }

    /// Locks the byte-stability invariants in `captureOMEMOFixture` so a
    /// regression that drops the prekey sort or changes the encoder output
    /// formatting can't silently re-introduce the spurious-rewrite class of
    /// bug.
    struct ByteStability {
        @Test func `sortedFixturePreKeys orders by keyID regardless of input order`() {
            let unsorted = [
                OMEMOStoredPreKey(accountJID: "alice@example.com", keyID: 7, keyData: Data(repeating: 0x07, count: 32), isUsed: false),
                OMEMOStoredPreKey(accountJID: "alice@example.com", keyID: 3, keyData: Data(repeating: 0x03, count: 32), isUsed: true),
                OMEMOStoredPreKey(accountJID: "alice@example.com", keyID: 5, keyData: Data(repeating: 0x05, count: 32), isUsed: false)
            ]
            let sorted = TestHarness.sortedFixturePreKeys(unsorted)
            #expect(sorted.map(\.keyID) == [3, 5, 7])
            #expect(sorted.map(\.isUsed) == [true, false, false])
        }

        @Test func `encodeFixture is byte-stable across two encodes of the same value`() throws {
            let fixture = FixtureOMEMOIdentity(
                deviceID: 1,
                identityKeyRaw: Array(repeating: 0x11, count: 32),
                signedPreKeyID: 7,
                signedPreKeyRaw: Array(repeating: 0x22, count: 32),
                signedPreKeySignature: Array(repeating: 0x33, count: 64),
                preKeys: [
                    FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32)),
                    FixtureOMEMOIdentity.PreKey(keyID: 2, keyRaw: Array(repeating: 0x55, count: 32), isUsed: true)
                ],
                accountJID: "alice@example.com"
            )
            let first = try TestHarness.encodeFixture(fixture)
            let second = try TestHarness.encodeFixture(fixture)
            #expect(first == second)
        }

        @Test func `encodeFixture differs when only isUsed flips`() throws {
            let unused = FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32), isUsed: false)
            let used = FixtureOMEMOIdentity.PreKey(keyID: 1, keyRaw: Array(repeating: 0x44, count: 32), isUsed: true)
            let baseline = FixtureOMEMOIdentity(
                deviceID: 1,
                identityKeyRaw: Array(repeating: 0x11, count: 32),
                signedPreKeyID: 7,
                signedPreKeyRaw: Array(repeating: 0x22, count: 32),
                signedPreKeySignature: Array(repeating: 0x33, count: 64),
                preKeys: [unused],
                accountJID: "alice@example.com"
            )
            let consumed = FixtureOMEMOIdentity(
                deviceID: 1,
                identityKeyRaw: Array(repeating: 0x11, count: 32),
                signedPreKeyID: 7,
                signedPreKeyRaw: Array(repeating: 0x22, count: 32),
                signedPreKeySignature: Array(repeating: 0x33, count: 64),
                preKeys: [used],
                accountJID: "alice@example.com"
            )
            let baselineBytes = try TestHarness.encodeFixture(baseline)
            let consumedBytes = try TestHarness.encodeFixture(consumed)
            #expect(baselineBytes != consumedBytes)
        }
    }
}
