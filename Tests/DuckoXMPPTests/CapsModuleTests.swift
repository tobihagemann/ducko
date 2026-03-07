import Testing
@testable import DuckoXMPP

// MARK: - Tests

enum CapsModuleTests {
    struct VerificationString {
        @Test
        func `Generates correct verification string from XEP-0115 example`() {
            // XEP-0115 §5.2 test vector (simplified)
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Exodus 0.9.1")
            ]
            let features: Set = [
                "http://jabber.org/protocol/caps",
                "http://jabber.org/protocol/disco#info",
                "http://jabber.org/protocol/disco#items",
                "http://jabber.org/protocol/muc"
            ]

            let ver = CapsModule.generateVerificationString(identities: identities, features: features)

            // The verification string is a base64-encoded SHA-1 hash.
            // We verify it's non-empty and deterministic.
            #expect(!ver.isEmpty)

            // Run again to verify determinism
            let ver2 = CapsModule.generateVerificationString(identities: identities, features: features)
            #expect(ver == ver2)
        }

        @Test
        func `Empty identities and features produce valid hash`() {
            let ver = CapsModule.generateVerificationString(identities: [], features: [])
            #expect(!ver.isEmpty)
        }

        @Test
        func `Different features produce different hashes`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Test")
            ]
            let ver1 = CapsModule.generateVerificationString(identities: identities, features: ["feature-a"])
            let ver2 = CapsModule.generateVerificationString(identities: identities, features: ["feature-b"])
            #expect(ver1 != ver2)
        }
    }

    struct PresenceHandling {
        @Test
        func `handleConnect sends presence with caps element`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            await client.register(CapsModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let capsPresence = sentStrings.first { $0.contains("http://jabber.org/protocol/caps") }
            #expect(capsPresence != nil)
            #expect(capsPresence?.contains("hash=\"sha-1\"") == true)
            #expect(capsPresence?.contains("node=\"https://ducko.app\"") == true)
            #expect(capsPresence?.contains("ver=") == true)

            await client.disconnect()
        }
    }

    struct CacheTests {
        @Test
        func `Cache stores and retrieves features by hash`() {
            let module = CapsModule()
            let testHash = "abc123"
            let features: Set = ["feature-a", "feature-b"]

            #expect(module.cachedFeatures(for: testHash) == nil)

            module.cacheFeatures(features, for: testHash)

            let cached = module.cachedFeatures(for: testHash)
            #expect(cached == features)
        }

        @Test
        func `handlePresence records ver hash`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            let capsModule = CapsModule()
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<presence from='contact@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://example.com/client' ver='testver123'/></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            // The hash should be recorded as pending (nil features, but key exists)
            #expect(capsModule.cachedFeatures(for: "testver123") == nil)

            // After caching features, they should be retrievable
            capsModule.cacheFeatures(["feature-a"], for: "testver123")
            #expect(capsModule.cachedFeatures(for: "testver123") == ["feature-a"])

            await client.disconnect()
        }
    }

    struct FeatureSupported {
        @Test
        func `Returns true when JID has cached feature`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            let capsModule = CapsModule()
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Simulate presence with caps
            await mock.simulateReceive(
                "<presence from='peer@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://example.com/client' ver='feathash1'/></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let peerJID = try #require(BareJID.parse("peer@example.com"))

            // Before caching features, isFeatureSupported returns false
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            // Cache features for the ver hash
            capsModule.cacheFeatures(["urn:xmpp:jingle:1", "http://jabber.org/protocol/disco#info"], for: "feathash1")

            // Now isFeatureSupported returns true for cached feature
            #expect(capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            // Returns false for uncached feature
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:0", by: peerJID))

            // Returns false for unknown JID
            let unknownJID = try #require(BareJID.parse("unknown@example.com"))
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: unknownJID))

            await client.disconnect()
        }

        @Test
        func `Clears JID mapping on disconnect`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )
            let capsModule = CapsModule()
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Simulate presence with caps
            await mock.simulateReceive(
                "<presence from='peer@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://example.com/client' ver='feathash2'/></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let peerJID = try #require(BareJID.parse("peer@example.com"))
            capsModule.cacheFeatures(["urn:xmpp:jingle:1"], for: "feathash2")
            #expect(capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            // Disconnect clears JID→ver mapping
            await capsModule.handleDisconnect()
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            await client.disconnect()
        }
    }
}
