import DuckoTestSupport
import Testing
@testable import DuckoXMPP

enum ConnectOrderingTests {
    // MARK: - Post-Handshake Ordering

    struct PostHandshakeOrdering {
        /// XEP-0163 §3.3.2: the caps-bearing presence (`CapsModule`) must reach the server before any PEP
        /// publisher. Asserts the plain presence, then the caps presence (caps last), then the first
        /// OMEMO connect-time stanza — proving the `presence → caps → PEP-publisher` ordering.
        @Test func `caps-bearing presence precedes the first PEP module stanza`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())
            await client.register(CapsModule())
            await client.register(pepModule)
            await client.register(omemoModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)

            // Plain presence (index 4), caps presence (index 5), then OMEMO's connect-time PEP IQs:
            // device-list retrieve (6), device-list publish (7), bundle publish (8).
            await mock.waitForSent(count: 7)
            let retrieveID = try await #require(extractIQID(from: mock.sentBytes[6]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(retrieveID)\"/>")
            await mock.waitForSent(count: 8)
            let publishID = try await #require(extractIQID(from: mock.sentBytes[7]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(publishID)\"/>")
            await mock.waitForSent(count: 9)
            let bundleID = try await #require(extractIQID(from: mock.sentBytes[8]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(bundleID)\"/>")

            try await connectTask.value

            let sent = await mock.sentBytes
            let strings = sent.map { String(decoding: $0, as: UTF8.self) }
            let plainPresenceIndex = try #require(strings.firstIndex {
                $0.contains("<presence") && !$0.contains(XMPPNamespaces.caps)
            })
            let capsPresenceIndex = try #require(strings.firstIndex {
                $0.contains("<presence") && $0.contains(XMPPNamespaces.caps)
            })
            let omemoIndex = try #require(strings.firstIndex { $0.contains(XMPPNamespaces.omemoDevices) })
            #expect(plainPresenceIndex < capsPresenceIndex)
            #expect(capsPresenceIndex < omemoIndex)

            await client.disconnect()
        }
    }

    // MARK: - Initial Presence Readiness Signal

    struct InitialPresenceReadiness {
        @Test func `resolves after presence and caps on a fresh connect`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())
            await client.register(CapsModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Presence + caps are fire-and-forget, so the gate is open once connect completes; reaching the
            // line after the await proves it resolved rather than hung.
            await client.awaitInitialPresenceSent()

            await client.disconnect()
        }

        @Test func `resolves immediately on a resumed session`() async throws {
            // Phase 1: connect with SM enabled to obtain a resume state.
            let mock1 = MockTransport()
            let sm1 = StreamManagementModule()
            let client1 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock1, requireTLS: false
            )
            await client1.register(sm1)
            await client1.addInterceptor(sm1)

            let connect1 = Task { try await client1.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock1, postAuthFeatures: testFeaturesBindWithSM)
            await mock1.waitForSent(count: 5) // SM <enable>
            await mock1.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>")
            try await connect1.value
            await mock1.simulateDisconnect()
            try? await Task.sleep(for: .milliseconds(100))
            let resumeState = try #require(sm1.resumeState)

            // Phase 2: reconnect, resuming the prior session (no bind, no presence/caps re-sent).
            let mock2 = MockTransport()
            let sm2 = StreamManagementModule(previousState: resumeState)
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            await client2.register(sm2)
            await client2.addInterceptor(sm2)

            let connect2 = Task { try await client2.connect(host: "example.com", port: 5222) }
            await mock2.waitForSent(count: 1)
            await mock2.simulateReceive(testServerStreamOpen)
            await mock2.simulateReceive(testFeaturesNoTLS)
            await mock2.waitForSent(count: 2)
            await mock2.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            await mock2.waitForSent(count: 3)
            await mock2.simulateReceive(testServerStreamOpen)
            await mock2.simulateReceive(testFeaturesBindWithSM)
            await mock2.waitForSent(count: 4) // <resume> sent instead of bind
            await mock2.simulateReceive("<resumed xmlns='urn:xmpp:sm:3' previd='sm-resume-1' h='0'/>")
            try await connect2.value

            await client2.awaitInitialPresenceSent()

            await mock2.simulateDisconnect()
        }

        @Test func `does not hang after a failed connect`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1)
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)
            await mock.waitForSent(count: 2) // auth element sent
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")

            await #expect(throws: (any Error).self) {
                try await connectTask.value
            }

            // The handshake-failure path opens the gate, so this resolves instead of hanging on a dead client.
            await client.awaitInitialPresenceSent()
        }

        @Test func `does not hang after the transport connect fails`() async throws {
            // The establish-failure catch is a distinct settle path from the handshake-failure one above: the
            // transport's connect throws before any handshake runs, so the gate must be opened by the
            // `establish()` catch rather than by the handshake catch. Deleting that settle hangs this await.
            let mock = MockTransport(connectError: XMPPConnectionError.connectionTimeout)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())

            await #expect(throws: (any Error).self) {
                try await client.connect(host: "example.com", port: 5222)
            }

            await client.awaitInitialPresenceSent()
        }

        @Test func `a waiter parked before the failure is resolved by it`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1)
            // Park the waiter only after the first stanza is on the wire. The connect-start re-gate runs
            // before `openStream` sends that stanza, so it has provably already executed — meaning this
            // parked waiter can be resolved only by the handshake-failure settle this test targets, not by
            // the re-gate. Exercises the path where a gated service is suspended when the connection fails.
            let waiter = Task { await client.awaitInitialPresenceSent() }

            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)
            await mock.waitForSent(count: 2) // auth element sent
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")

            await #expect(throws: (any Error).self) {
                try await connectTask.value
            }

            // The parked waiter is resolved by the failure path within a bound rather than hanging forever.
            let resolved = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await waiter.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(resolved)
        }

        @Test func `connection loss while the gate is closed resolves a parked waiter`() async {
            // The cleanUp / connection-lost settle is a distinct path from the connect-time failure catches:
            // here the session reaches `.connected` and a service parks on the gate, but the connection drops
            // before the caps presence opens it. Hold caps off the wire so the gate stays closed across the
            // teardown, proving cleanUp's settle (not the caps settle) is what releases the waiter. Deleting
            // that settle hangs this await.
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())
            await client.register(CapsModule())

            await mock.blockSends { $0.contains(XMPPNamespaces.caps) }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            // Plain presence (stanza 5) goes out; the caps presence (stanza 6) is blocked, so the gate's
            // caps settle is never reached and the gate stays closed.
            await mock.waitForSent(count: 5)

            let waiter = Task { await client.awaitInitialPresenceSent() }
            try? await Task.sleep(for: .milliseconds(50))

            // Connection lost mid-startup → cleanUp settles the still-closed gate.
            await mock.simulateDisconnect()

            let resolved = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await waiter.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(resolved)

            await mock.releaseBlockedSends()
            connectTask.cancel()
        }

        @Test func `the gate stays closed until the caps presence is sent`() async {
            // Negative assertion guarding the ordering invariant directly: a regression that opened the gate
            // early — at `.connected`, after the plain presence, or before `CapsModule.handleConnect()`
            // completes — would still pass the positive resolution tests. Hold the caps presence off the wire,
            // park a waiter, and confirm it stays suspended; only releasing caps may resolve it.
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())
            await client.register(CapsModule())

            await mock.blockSends { $0.contains(XMPPNamespaces.caps) }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            await mock.waitForSent(count: 5) // plain presence out; caps (stanza 6) blocked

            // Use an unstructured task that records resolution into an actor flag rather than a task-group
            // race: the gate await is a non-cancellable `CheckedContinuation`, so an abandoned waiter inside a
            // task group would block the group at scope exit while the gate is deliberately held closed.
            let probe = GateProbe()
            let waiter = Task { await client.awaitInitialPresenceSent(); await probe.markOpen() }

            // While caps is held off the wire the gate must NOT open.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(await probe.isOpen == false)

            // Releasing caps sends it, reaching the post-caps settle; the gate then opens.
            await mock.releaseBlockedSends()
            var opened = false
            for _ in 0 ..< 100 {
                if await probe.isOpen { opened = true; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(opened)

            waiter.cancel()
            await client.disconnect()
            connectTask.cancel()
        }
    }
}

/// Records whether the readiness gate opened, for the negative-assertion test above. An actor (rather than a
/// task-group race) is required because the gate await is a non-cancellable `CheckedContinuation`: a waiter
/// abandoned mid-suspension would otherwise block its enclosing task group from ever returning.
private actor GateProbe {
    private(set) var isOpen = false
    func markOpen() {
        isOpen = true
    }
}
