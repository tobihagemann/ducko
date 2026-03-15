import CryptoKit
import Testing
@testable import DuckoXMPP

enum OMEMOSerializationTests {
    // MARK: - Double Ratchet Session

    struct SessionSerializationTests {
        @Test func `initiator session round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let peerKey = Curve25519.KeyAgreement.PrivateKey()
            let peerPublicBytes = Array(peerKey.publicKey.rawRepresentation)

            let session = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret,
                peerSignedPreKey: peerPublicBytes
            )

            let serialized = session.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(Array(restored.dhSendKeyPair.rawRepresentation) == Array(session.dhSendKeyPair.rawRepresentation))
            #expect(restored.dhRecvPublicKey == session.dhRecvPublicKey)
            #expect(restored.rootKey == session.rootKey)
            #expect(restored.sendChainKey == session.sendChainKey)
            #expect(restored.recvChainKey == session.recvChainKey)
            #expect(restored.sendMessageNumber == session.sendMessageNumber)
            #expect(restored.recvMessageNumber == session.recvMessageNumber)
            #expect(restored.previousSendCount == session.previousSendCount)
        }

        @Test func `responder session round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let ourKeyPair = Curve25519.KeyAgreement.PrivateKey()

            let session = OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: sharedSecret,
                ourSignedPreKeyPair: ourKeyPair
            )

            let serialized = session.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(Array(restored.dhSendKeyPair.rawRepresentation) == Array(session.dhSendKeyPair.rawRepresentation))
            #expect(restored.dhRecvPublicKey == nil)
            #expect(restored.rootKey == session.rootKey)
            #expect(restored.sendChainKey == nil)
            #expect(restored.recvChainKey == nil)
        }

        @Test func `session after encryption round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let peerKey = Curve25519.KeyAgreement.PrivateKey()
            let peerPublicBytes = Array(peerKey.publicKey.rawRepresentation)
            let ad = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }

            var session = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret,
                peerSignedPreKey: peerPublicBytes
            )

            // Encrypt a few messages to advance the ratchet
            _ = try session.encrypt(plaintext: Array("Hello".utf8), associatedData: ad)
            _ = try session.encrypt(plaintext: Array("World".utf8), associatedData: ad)

            let serialized = session.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(restored.sendMessageNumber == 2)
            #expect(restored.sendChainKey == session.sendChainKey)
            #expect(restored.rootKey == session.rootKey)

            // Verify restored session can continue encrypting
            var mutable = restored
            let msg = try mutable.encrypt(plaintext: Array("Test".utf8), associatedData: ad)
            #expect(msg.header.messageNumber == 2)
        }

        @Test func `session with skipped keys round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let bobKeyPair = Curve25519.KeyAgreement.PrivateKey()
            let ad = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }

            // Alice initiates
            var alice = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret,
                peerSignedPreKey: Array(bobKeyPair.publicKey.rawRepresentation)
            )

            // Bob responds
            var bob = OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: sharedSecret,
                ourSignedPreKeyPair: bobKeyPair
            )

            // Alice sends 3 messages
            let msg0 = try alice.encrypt(plaintext: Array("msg0".utf8), associatedData: ad)
            _ = try alice.encrypt(plaintext: Array("msg1".utf8), associatedData: ad)
            let msg2 = try alice.encrypt(plaintext: Array("msg2".utf8), associatedData: ad)

            // Bob receives msg2 first (skipping msg1)
            _ = try bob.decrypt(message: msg2, associatedData: ad)
            // Bob receives msg0 (using skipped key from before ratchet)
            _ = try bob.decrypt(message: msg0, associatedData: ad)

            // Bob should have msg1's key stored as skipped
            let skippedCount = bob.skippedMessageKeys.count
            #expect(skippedCount == 1)

            // Serialize and restore
            let serialized = bob.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(restored.skippedMessageKeys.count == skippedCount)
            #expect(restored.skippedKeyOrder.count == skippedCount)
        }
    }

    // MARK: - Skipped Key ID

    struct SkippedKeyIDTests {
        @Test func `public init and hash`() {
            let key = SkippedKeyID(publicKey: [1, 2, 3], messageNumber: 42)
            #expect(key.publicKey == [1, 2, 3])
            #expect(key.messageNumber == 42)

            let same = SkippedKeyID(publicKey: [1, 2, 3], messageNumber: 42)
            #expect(key == same)

            let different = SkippedKeyID(publicKey: [1, 2, 3], messageNumber: 43)
            #expect(key != different)
        }
    }
}
