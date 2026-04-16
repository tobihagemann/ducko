import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct AvatarTests {
        // MARK: - Service Layer

        /// Precondition (documented in `TestCredentials`): alice and bob have a
        /// pre-existing mutual roster subscription so PEP+ notifications flow.
        @Test(.timeLimit(.minutes(1))) @MainActor func `Publishing Alice's avatar changes ownAvatarHash and reaches Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceJID = try #require(BareJID.parse(TestCredentials.alice.jid))

                // Fetch Alice's current avatar directly rather than reading
                // ownAvatarHash — the service has a single shared ownAvatarHash
                // slot that multi-account connect races can overwrite with
                // another account's hash, leading cleanup to restore the wrong
                // operator's avatar.
                let originalAvatar = await harness.environment.avatarService.fetchAvatar(for: aliceJID, accountID: alice.accountID)

                harness.addCleanup {
                    if let originalAvatar {
                        try? await harness.environment.avatarService.publishAvatar(
                            imageData: originalAvatar.data,
                            mimeType: originalAvatar.mimeType,
                            accountID: alice.accountID
                        )
                    } else {
                        try? await harness.environment.avatarService.removeAvatar(accountID: alice.accountID)
                    }
                }

                let imageData = Self.minimalPNGData()
                let expectedHash = sha1Hex(Array(imageData))
                try await harness.environment.avatarService.publishAvatar(
                    imageData: imageData, mimeType: "image/png", accountID: alice.accountID
                )

                // Prosody's mod_pep doesn't fan `+notify` events back to the
                // publisher's own resources, so alice's own-account publish is
                // verified locally: `publishAvatar` sets `ownAvatarHash` only
                // after the avatar-data and avatar-metadata PEP publish IQs
                // both succeed.
                #expect(harness.environment.avatarService.ownAvatarHash == expectedHash)

                // Bob sees either the PEP+ metadata publish or the XEP-0153
                // vCard fallback — both count as cross-account visibility.
                // Match on the newly-published hash specifically so a
                // connect-time sync of Alice's prior avatar can't satisfy it.
                _ = try await bob.waitForEvent { event in
                    if case let .pepItemsPublished(from, node, items) = event,
                       from == aliceJID, node == XMPPNamespaces.avatarMetadata,
                       items.contains(where: { $0.id == expectedHash }) {
                        return true
                    }
                    if case let .vcardAvatarHashReceived(from, hash) = event,
                       from == aliceJID, hash == expectedHash {
                        return true
                    }
                    return false
                }
            }
        }

        /// Precondition (documented in `TestCredentials`): alice and bob have a
        /// pre-existing mutual roster subscription so alice has presence-access
        /// to bob's avatar PEP nodes (`urn:xmpp:avatar:data`/`:metadata` default
        /// to `access_model=presence`).
        @Test(.timeLimit(.minutes(1))) @MainActor func `Alice fetches Bob's avatar after Bob publishes`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let priorBobAvatar = await harness.environment.avatarService.fetchAvatar(for: bobJID, accountID: bob.accountID)

                harness.addCleanup {
                    if let priorBobAvatar {
                        try? await harness.environment.avatarService.publishAvatar(
                            imageData: priorBobAvatar.data,
                            mimeType: priorBobAvatar.mimeType,
                            accountID: bob.accountID
                        )
                    } else {
                        try? await harness.environment.avatarService.removeAvatar(accountID: bob.accountID)
                    }
                }

                let imageData = Self.minimalPNGData()
                let expectedHash = sha1Hex(Array(imageData))
                try await harness.environment.avatarService.publishAvatar(
                    imageData: imageData, mimeType: "image/png", accountID: bob.accountID
                )

                let result = try #require(await harness.environment.avatarService.fetchAvatar(for: bobJID, accountID: alice.accountID))
                #expect(result.data == imageData)
                #expect(result.hash == expectedHash)
            }
        }

        // MARK: - Fixture

        /// Pinned literal guards the cross-account hashing path against regressions:
        /// the live tests above assert `result.hash == sha1Hex(Array(imageData))`,
        /// which is self-referential because both sides use the same helper.
        @Test func `Minimal PNG fixture hashes to pinned SHA-1`() {
            #expect(sha1Hex(Array(Self.minimalPNGData())) == "6de4acdaec8ea4383383217fac75f48070ad1076")
        }

        // MARK: - Helpers

        /// Returns a minimal valid 1x1 PNG. Bytes are deterministic and
        /// dependency-free (no CoreGraphics) so the test runs identically in
        /// every environment.
        private static func minimalPNGData() -> Data {
            Data([
                // PNG signature
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                // IHDR chunk
                0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x00, 0x00, 0x00, 0x00, 0x3B, 0x7E, 0x9B, 0x55,
                // IDAT chunk
                0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54,
                0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
                0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
                // IEND chunk
                0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
                0xAE, 0x42, 0x60, 0x82
            ])
        }
    }
}
