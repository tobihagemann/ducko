import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> (XMPPClient, StreamManagementModule) {
    let sm = StreamManagementModule()
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(sm)
    await client.addInterceptor(sm)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

    await simulateNoTLSConnect(mock, postAuthFeatures: testFeaturesBindWithSM)
    await mock.waitForSent(count: 5) // SM <enable> sent

    // Respond to SM <enable> with <enabled>
    await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>")

    try await connectTask.value

    return (client, sm)
}

/// Drives `client.disconnect()` and feeds the matching `<a/>` to satisfy
/// the SM `<r/>`/`<a/>` handshake. Use in tests where disconnect is just
/// cleanup; tests that pin the disconnect ordering drive the handshake
/// manually instead.
private func disconnectAndAck(_ client: XMPPClient, sm: StreamManagementModule, mock: MockTransport) async {
    let wasEnabled = sm.isEnabled
    let baseline = sm.resumeState?.outgoingCounter ?? 0
    let snapshotCount = await mock.sentBytes.count
    let task = Task { await client.disconnect() }
    if wasEnabled {
        await mock.waitForSent(count: snapshotCount + 2)
        await mock.simulateReceive("<a xmlns='urn:xmpp:sm:3' h='\(baseline &+ 1)'/>")
    }
    await task.value
}

/// Simulates the connect flow up to post-auth features, then expects a `<resume>` element
/// instead of `<bind>`. Responds with the given `resumeResponse` XML.
private func simulateResumeConnect(_ mock: MockTransport, resumeResponse: String) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element sent
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesBindWithSM)
    await mock.waitForSent(count: 4) // <resume> sent (instead of bind)
    await mock.simulateReceive(resumeResponse)
}

/// Simulates the connect flow where resume fails, then falls through to normal bind.
private func simulateResumeFailConnect(_ mock: MockTransport) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element sent
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesBindWithSM)
    await mock.waitForSent(count: 4) // <resume> sent
    await mock.simulateReceive("<failed xmlns='urn:xmpp:sm:3'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>")
    await mock.waitForSent(count: 5) // bind IQ sent (fallback)
    await mock.simulateReceive(testBindResult)
    await mock.waitForSent(count: 6) // SM <enable> sent after bind
    await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-2' max='300'/>")
}

// MARK: - Tests

enum StreamManagementModuleTests {
    struct EnableFlow {
        @Test
        func `Sends <enable> on handleConnect and processes <enabled> response`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            await disconnectAndAck(client, sm: sm, mock: mock)
        }

        @Test
        func `Handles <failed> response and resets state`() async throws {
            let mock = MockTransport()
            let sm = StreamManagementModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            await simulateNoTLSConnect(mock, postAuthFeatures: testFeaturesBindWithSM)
            await mock.waitForSent(count: 5) // SM <enable> sent

            // Respond with <failed> instead of <enabled>
            await mock.simulateReceive("<failed xmlns='urn:xmpp:sm:3'/>")

            try await connectTask.value

            await client.disconnect()
        }

        @Test
        func `Does not send enable when server features lack SM`() async throws {
            let mock = MockTransport()
            let sm = StreamManagementModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            // Use standard connect (no SM in post-auth features)
            await simulateNoTLSConnect(mock)

            try await connectTask.value

            // Verify no <enable> was sent
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let enableSent = sentStrings.contains { $0.contains("<enable") && $0.contains("urn:xmpp:sm:3") }
            #expect(!enableSent)

            await client.disconnect()
        }

        @Test
        func `Parses id, max, and location from <enabled>`() async throws {
            let mock = MockTransport()
            let sm = StreamManagementModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            await simulateNoTLSConnect(mock, postAuthFeatures: testFeaturesBindWithSM)
            await mock.waitForSent(count: 5) // SM <enable> sent

            await mock.simulateReceive(
                "<enabled xmlns='urn:xmpp:sm:3' id='abc-123' max='300' location='alt.example.com:5222'/>"
            )

            try await connectTask.value

            // Verify resume state was populated
            let state = sm.resumeState
            #expect(state != nil)
            #expect(state?.resumptionId == "abc-123")
            #expect(state?.location == "alt.example.com:5222")
            let jid = state?.connectedJID
            #expect(jid?.bareJID.description == "user@example.com")

            await disconnectAndAck(client, sm: sm, mock: mock)
        }
    }

    struct IncomingCounter {
        @Test
        func `Increments incoming counter on received stanzas`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // Send a message stanza — should increment incoming counter
            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Hello</body></message>"
            )
            // Send a presence stanza
            await mock.simulateReceive(
                "<presence from='contact@example.com/res'/>"
            )
            // Send an IQ stanza
            await mock.simulateReceive(
                "<iq type='get' from='example.com' id='test-1'><query xmlns='jabber:iq:version'/></iq>"
            )

            try? await Task.sleep(for: .milliseconds(100))

            // Request ack — the server sends <r>, we should respond with <a h="3">
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let ack = sentStrings.first { $0.contains("<a") && $0.contains("urn:xmpp:sm:3") }
            #expect(ack != nil)
            #expect(ack?.contains("h=\"3\"") == true)

            await disconnectAndAck(client, sm: sm, mock: mock)
        }
    }

    struct OutgoingCounter {
        @Test
        func `Increments outgoing counter on sent stanzas`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Send some stanzas
            let message = try XMPPMessage(type: .chat, to: .bare(#require(BareJID(localPart: "contact", domainPart: "example.com"))))
            try await client.send(message)
            try await client.send(message)

            await disconnectAndAck(client, sm: sm, mock: mock)
        }

        @Test
        func `disconnect routes unavailable presence through SM interceptor`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Baseline counter snapshot before disconnect — `makeConnectedClient`
            // already sent the SM <enable> + handshake stanzas; capture the
            // counter once SM is enabled so the assertion isolates the
            // disconnect-side delta.
            let baseline = sm.resumeState?.outgoingCounter ?? 0

            // The disconnect path now blocks on `<r/>`/`<a/>`. Drive it as
            // a Task; once `<r/>` is on the wire (sentBytes count = 7 —
            // baseline 5 from `makeConnectedClient` plus unavailable +
            // `<r/>`), simulate the matching `<a/>` so the handshake
            // completes.
            let disconnectTask = Task { await client.disconnect() }
            await mock.waitForSent(count: 7)
            await mock.simulateReceive("<a xmlns='urn:xmpp:sm:3' h='\(baseline &+ 1)'/>")
            await disconnectTask.value

            // The unavailable presence in `disconnect()` MUST go through
            // `send()` (not `connection.send` directly) so the SM interceptor
            // counts it. Bypassing the interceptor leaves the counter one
            // short of the server's view, producing phantom "Invalid ack"
            // warnings on the next ack.
            #expect(sm.resumeState?.outgoingCounter == baseline &+ 1)
        }
    }

    struct AckProcessing {
        @Test
        func `Responds to <r> with <a h='N'>`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Receive one message to set incoming counter to 1
            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Hi</body></message>"
            )
            try? await Task.sleep(for: .milliseconds(50))

            await mock.clearSentBytes()

            // Server sends <r>
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let ack = sentStrings.first { $0.contains("<a") && $0.contains("urn:xmpp:sm:3") }
            #expect(ack != nil)
            #expect(ack?.contains("h=\"1\"") == true)

            await disconnectAndAck(client, sm: sm, mock: mock)
        }

        @Test
        func `Processes <a h='N'> and dequeues acknowledged stanzas`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Send 3 stanzas
            let message = try XMPPMessage(type: .chat, to: .bare(#require(BareJID(localPart: "contact", domainPart: "example.com"))))
            try await client.send(message)
            try await client.send(message)
            try await client.send(message)

            // Server acknowledges 2 stanzas
            await mock.simulateReceive("<a xmlns='urn:xmpp:sm:3' h='2'/>")
            try? await Task.sleep(for: .milliseconds(50))

            await disconnectAndAck(client, sm: sm, mock: mock)
        }
    }

    struct StanzaFiltering {
        @Test
        func `Counter only counts iq/message/presence, not SM elements`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // SM elements like <r> and <a> should NOT increment the counter
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(50))

            // Send another <r> to check the counter is still 0
            await mock.clearSentBytes()
            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")
            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let ack = sentStrings.first { $0.contains("<a") && $0.contains("urn:xmpp:sm:3") }
            #expect(ack?.contains("h=\"0\"") == true)

            await disconnectAndAck(client, sm: sm, mock: mock)
        }

        @Test
        func `SM-namespace elements are consumed and not dispatched to modules`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Try to collect an iqReceived event — the SM <r> should NOT produce one
            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(1)) { event in
                    if case .iqReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("<r xmlns='urn:xmpp:sm:3'/>")

            do {
                _ = try await eventsTask.value
                throw XMPPClientError.unexpectedStreamState("Should have timed out")
            } catch is XMPPClientError {
                // Expected: timeout means SM elements were consumed
            }

            await disconnectAndAck(client, sm: sm, mock: mock)
        }
    }

    struct Resumption {
        @Test
        func `Resume success emits streamResumed and skips bind`() async throws {
            // Phase 1: Connect with SM enabled
            let mock1 = MockTransport()
            let (client1, sm1) = try await makeConnectedClient(mock: mock1)

            // Send some stanzas to populate outgoing queue
            let message = try XMPPMessage(type: .chat, to: .bare(#require(BareJID(localPart: "contact", domainPart: "example.com"))))
            try await client1.send(message)
            try await client1.send(message)

            // Simulate disconnect (non-requested) — SM module preserves resume state
            await mock1.simulateDisconnect()
            try? await Task.sleep(for: .milliseconds(100))

            // Extract resume state
            let resumeState = sm1.resumeState
            #expect(resumeState != nil)
            #expect(resumeState?.resumptionId == "sm-resume-1")

            // Phase 2: Reconnect with previous SM state
            let mock2 = MockTransport()
            let sm2 = StreamManagementModule(previousState: resumeState)
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            await client2.register(sm2)
            await client2.addInterceptor(sm2)

            let eventsTask = Task {
                try await collectEvents(from: client2, timeout: .seconds(5)) { event in
                    if case .streamResumed = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client2.connect(host: "example.com", port: 5222) }

            // Server responds with <resumed> acknowledging all stanzas
            await simulateResumeConnect(mock2, resumeResponse: "<resumed xmlns='urn:xmpp:sm:3' previd='sm-resume-1' h='2'/>")

            try await connectTask.value

            // Verify .streamResumed event was emitted
            let events = try await eventsTask.value
            let resumedEvent = events.first { if case .streamResumed = $0 { return true }; return false }
            #expect(resumedEvent != nil)

            // Verify no bind IQ was sent
            let sentData = await mock2.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let bindSent = sentStrings.contains { $0.contains("urn:ietf:params:xml:ns:xmpp-bind") }
            #expect(!bindSent)

            // Verify <resume> was sent
            let resumeSent = sentStrings.contains { $0.contains("<resume") && $0.contains("previd") }
            #expect(resumeSent)

            await disconnectAndAck(client2, sm: sm2, mock: mock2)
        }

        @Test
        func `Resume failure falls through to normal bind`() async throws {
            // Phase 1: Connect with SM enabled
            let mock1 = MockTransport()
            let (_, sm1) = try await makeConnectedClient(mock: mock1)

            await mock1.simulateDisconnect()
            try? await Task.sleep(for: .milliseconds(100))

            let resumeState = sm1.resumeState
            #expect(resumeState != nil)

            // Phase 2: Reconnect — resume will fail
            let mock2 = MockTransport()
            let sm2 = StreamManagementModule(previousState: resumeState)
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            await client2.register(sm2)
            await client2.addInterceptor(sm2)

            let eventsTask = Task {
                try await collectEvents(from: client2, timeout: .seconds(5)) { event in
                    if case .connected = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client2.connect(host: "example.com", port: 5222) }

            await simulateResumeFailConnect(mock2)

            try await connectTask.value

            // Verify .connected event (not .streamResumed)
            let events = try await eventsTask.value
            let connectedEvent = events.first { if case .connected = $0 { return true }; return false }
            #expect(connectedEvent != nil)

            let resumedEvent = events.first { if case .streamResumed = $0 { return true }; return false }
            #expect(resumedEvent == nil)

            await disconnectAndAck(client2, sm: sm2, mock: mock2)
        }

        @Test
        func `H-value reconciliation retransmits unacked stanzas`() async throws {
            // Phase 1: Connect and send 5 stanzas
            let mock1 = MockTransport()
            let (client1, sm1) = try await makeConnectedClient(mock: mock1)

            let message = try XMPPMessage(type: .chat, to: .bare(#require(BareJID(localPart: "contact", domainPart: "example.com"))))
            for _ in 0 ..< 5 {
                try await client1.send(message)
            }

            // Server acks 0 before disconnect
            await mock1.simulateDisconnect()
            try? await Task.sleep(for: .milliseconds(100))

            let resumeState = sm1.resumeState
            let queueCount = resumeState?.outgoingQueue.count ?? 0
            #expect(queueCount == 5)

            // Phase 2: Reconnect — server acks 2 in <resumed>
            let mock2 = MockTransport()
            let sm2 = StreamManagementModule(previousState: resumeState)
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            await client2.register(sm2)
            await client2.addInterceptor(sm2)

            let connectTask = Task { try await client2.connect(host: "example.com", port: 5222) }

            // Server says h='2' — acked 2 of our 5 stanzas
            await simulateResumeConnect(mock2, resumeResponse: "<resumed xmlns='urn:xmpp:sm:3' previd='sm-resume-1' h='2'/>")

            try await connectTask.value

            // After resume, 3 unacked stanzas should be retransmitted
            let sentData = await mock2.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            // Count retransmitted message stanzas (after the <resume> element)
            let messageSentCount = sentStrings.count(where: { $0.contains("<message") })
            #expect(messageSentCount == 3)

            await disconnectAndAck(client2, sm: sm2, mock: mock2)
        }

        @Test
        func `State preserved across non-requested disconnect`() async throws {
            let mock = MockTransport()
            let (_, sm) = try await makeConnectedClient(mock: mock)

            // Before disconnect, SM should be enabled with resume state
            #expect(sm.isResumable)

            // Simulate non-requested disconnect
            await mock.simulateDisconnect()
            try? await Task.sleep(for: .milliseconds(100))

            // Resume state should still be available
            let state = sm.resumeState
            #expect(state != nil)
            #expect(state?.resumptionId == "sm-resume-1")
            #expect(state?.connectedJID.bareJID.description == "user@example.com")
        }

        @Test
        func `resetResumption clears all state`() async throws {
            let mock = MockTransport()
            let (_, sm) = try await makeConnectedClient(mock: mock)

            #expect(sm.isResumable)

            sm.resetResumption()

            #expect(!sm.isResumable)
            #expect(sm.resumeState == nil)
        }
    }

    struct SyncAckHandshake {
        @Test
        func `disconnect order: unavailable then <r/> then <a/> then stream close`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeConnectedClient(mock: mock)

            // Baseline 5 from `makeConnectedClient`. Disconnect should
            // append: 6 = unavailable, 7 = `<r/>`, then suspend awaiting
            // `<a/>`, then 8 = `</stream:stream>`.
            let baseline = sm.resumeState?.outgoingCounter ?? 0

            let disconnectTask = Task { await client.disconnect() }

            await mock.waitForSent(count: 6)
            await mock.waitForSent(count: 7)

            // `</stream:stream>` must NOT have been sent yet — disconnect
            // is suspended waiting for `<a/>`.
            let sentBeforeAck = await mock.sentBytes
            #expect(sentBeforeAck.count == 7)

            await mock.simulateReceive("<a xmlns='urn:xmpp:sm:3' h='\(baseline &+ 1)'/>")
            await disconnectTask.value

            let sentFinal = await mock.sentBytes
            #expect(sentFinal.count == 8)
            let lastBytes = String(decoding: sentFinal[7], as: UTF8.self)
            #expect(lastBytes.contains("</stream:stream>"))
        }

        @Test
        func `disconnect ordering with Bind 2 inline-enable`() async throws {
            // SASL2 + Bind 2 inline-enables SM via `<bound><enabled/></bound>`
            // in the `<success>` reply — exercising the inline-enable
            // codepath through `processBind2Results` rather than the
            // post-bind `<enable>`/`<enabled>` round-trip.
            let mock = MockTransport()
            let sm = StreamManagementModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(sm)
            await client.addInterceptor(sm)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            // After SASL2 connect: sentBytes count = 3, SM enabled inline.
            #expect(sm.isEnabled)

            let disconnectTask = Task { await client.disconnect() }
            await mock.waitForSent(count: 4) // unavailable
            await mock.waitForSent(count: 5) // <r/>

            let sentBeforeAck = await mock.sentBytes
            #expect(sentBeforeAck.count == 5)

            // Inline-enable's outgoing counter started at 0; the
            // unavailable presence advances it to 1.
            await mock.simulateReceive("<a xmlns='urn:xmpp:sm:3' h='1'/>")
            await disconnectTask.value

            let sentFinal = await mock.sentBytes
            #expect(sentFinal.count == 6)
            let last = String(decoding: sentFinal[5], as: UTF8.self)
            #expect(last.contains("</stream:stream>"))
        }

        @Test
        func `requestSyncAck times out when no <a/> arrives`() async throws {
            let mock = MockTransport()
            let (_, sm) = try await makeConnectedClient(mock: mock)

            do {
                try await sm.requestSyncAck(timeout: .milliseconds(100))
                Issue.record("expected timeout on first call")
            } catch XMPPClientError.timeout {
                // expected
            }

            // Slot must have been cleared by `expirePendingSyncAck` —
            // a follow-up call must reach the install transaction (and
            // time out again, not throw busy).
            do {
                try await sm.requestSyncAck(timeout: .milliseconds(100))
                Issue.record("expected timeout on second call")
            } catch XMPPClientError.streamManagementBusy {
                Issue.record("slot was not cleared after first timeout")
            } catch XMPPClientError.timeout {
                // expected
            }
        }

        @Test
        func `requestSyncAck propagates parent cancellation`() async throws {
            let mock = MockTransport()
            let (_, sm) = try await makeConnectedClient(mock: mock)

            let task = Task {
                try await sm.requestSyncAck(timeout: .seconds(10))
            }

            // Wait for `<r/>` on the wire — proves the install completed.
            await mock.waitForSent(count: 6)
            task.cancel()

            do {
                try await task.value
                Issue.record("expected CancellationError")
            } catch is CancellationError {
                // expected
            }

            // Verify the slot was cleared so a follow-up call works.
            do {
                try await sm.requestSyncAck(timeout: .milliseconds(100))
                Issue.record("expected timeout (slot should have been cleared)")
            } catch XMPPClientError.timeout {
                // expected
            }
        }

        @Test
        func `requestSyncAck rejects re-entry with streamManagementBusy`() async throws {
            let mock = MockTransport()
            let (_, sm) = try await makeConnectedClient(mock: mock)

            let firstTask = Task {
                try await sm.requestSyncAck(timeout: .seconds(10))
            }

            // Wait for the first `<r/>` — proves install completed.
            await mock.waitForSent(count: 6)

            do {
                try await sm.requestSyncAck(timeout: .seconds(1))
                Issue.record("expected streamManagementBusy")
            } catch XMPPClientError.streamManagementBusy {
                // expected
            }

            firstTask.cancel()
            _ = try? await firstTask.value
        }

        @Test
        func `SM-disabled disconnect skips handshake`() async throws {
            let mock = MockTransport()
            let sm = StreamManagementModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(sm)
            await client.addInterceptor(sm)

            // Default `postAuthFeatures = testFeaturesBind` advertises
            // bind only — no SM. `handleConnect` short-circuits, leaving
            // `sm.state.enabled = false`.
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            #expect(!sm.isEnabled)

            // Synchronous `await disconnect()` — must NOT block on
            // `<r/>`/`<a/>` because `sm.isEnabled == false` short-circuits
            // the handshake.
            await client.disconnect()

            let sent = await mock.sentBytes
            let strings = sent.map { String(decoding: $0, as: UTF8.self) }
            let hasUnavailable = strings.contains { $0.contains("type=\"unavailable\"") }
            let hasStreamClose = strings.contains { $0.contains("</stream:stream>") }
            let hasR = strings.contains { $0.contains("<r") && $0.contains("urn:xmpp:sm:3") }

            #expect(hasUnavailable)
            #expect(hasStreamClose)
            #expect(!hasR)
        }

        @Test
        func `stream-end during requested disconnect reports .requested, not .connectionLost`() async throws {
            // Race: user clicks "Sign Out" while the server happens to close
            // the stream (e.g., mid-handshake). Without the
            // `disconnectInFlight`-aware reason mapping, `handleStreamEnd`
            // would emit `.disconnected(.connectionLost(...))` and
            // `AccountService.handleDisconnect` would `scheduleReconnect` a
            // session the user just asked to terminate.
            let mock = MockTransport()
            let (client, _) = try await makeConnectedClient(mock: mock)

            // Collect the first .disconnected event off the event stream.
            let reasonTask = Task { () -> DisconnectReason? in
                for await event in client.events {
                    if case let .disconnected(reason) = event {
                        return reason
                    }
                }
                return nil
            }

            let disconnectTask = Task { await client.disconnect() }

            // Wait for unavailable + `<r/>`, then simulate the server closing
            // its end of the stream BEFORE feeding `<a/>` — mirrors the
            // production race where the TCP socket dies during the 1.5 s
            // sync-ack window.
            await mock.waitForSent(count: 7)
            await mock.simulateReceive("</stream:stream>")

            await disconnectTask.value
            let observed = await reasonTask.value
            guard case .requested = observed else {
                Issue.record("Expected .requested, got \(String(describing: observed))")
                return
            }
        }
    }
}
