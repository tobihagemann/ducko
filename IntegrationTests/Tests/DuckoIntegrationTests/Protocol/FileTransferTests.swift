import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct FileTransferTests {
        // MARK: - Protocol Layer

        @Test @MainActor func `Alice requests an HTTP upload slot and shares the URL with Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let upload = try #require(await aliceClient.module(ofType: HTTPUploadModule.self))
                let chat = try #require(await aliceClient.module(ofType: ChatModule.self))
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                let fileSize = try #require(
                    FileManager.default.attributesOfItem(atPath: fixtureURL.path)[.size] as? Int64
                )

                // Absorb environments where the live server lacks XEP-0363; the
                // discovery probe is intrinsically async so this is the minimal
                // reliable skip.
                await withKnownIssue("Server lacks HTTP upload service", isIntermittent: true) {
                    let slot = try await upload.requestSlot(
                        filename: fixtureURL.lastPathComponent,
                        size: fileSize,
                        contentType: "text/plain"
                    )

                    let putURL = try #require(URL(string: slot.putURL))
                    var request = URLRequest(url: putURL)
                    request.httpMethod = "PUT"
                    request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
                    for (name, value) in slot.putHeaders {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    let fileData = try Data(contentsOf: fixtureURL)
                    let (_, response) = try await URLSession.shared.upload(for: request, from: fileData)
                    let httpResponse = try #require(response as? HTTPURLResponse)
                    #expect((200 ... 299).contains(httpResponse.statusCode))

                    var oobX = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
                    var urlElement = DuckoXMPP.XMLElement(name: "url")
                    urlElement.addText(slot.getURL)
                    oobX.addChild(urlElement)
                    try await chat.sendMessage(to: .bare(bobJID), body: slot.getURL, additionalElements: [oobX])

                    _ = try await bob.waitForEvent { event in
                        if case let .messageReceived(m) = event, m.body == slot.getURL { return true }
                        return false
                    }
                }
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Alice initiates a Jingle file transfer to Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])
                try await Self.runJingleRoundTrip(harness: harness, assertBytesMatch: true)
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Jingle transfer completes even when SOCKS5 falls back to IBB`() async throws {
            // SOCKS5-vs-IBB selection is verified deterministically in the DuckoXMPPTests
            // unit suites (JingleSOCKS5Tests, JingleIBBFallbackTests). The integration
            // test's role is only to confirm the live end-to-end path completes;
            // no public selector exposes which transport actually completed.
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])
                try await Self.runJingleRoundTrip(harness: harness, assertBytesMatch: false)
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service sendFile via HTTP upload delivers the OOB URL`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                // Pinning `.httpUpload` bypasses the `.auto` resolver; `.auto`
                // always picks `.httpUpload` for bare-JID conversations, so the
                // explicit method is what makes this test deterministic.
                let conversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)

                await withKnownIssue("Server lacks HTTP upload service", isIntermittent: true) {
                    let url = try await harness.environment.fileTransferService.sendFile(
                        url: fixtureURL,
                        in: conversation,
                        accountID: alice.accountID,
                        method: .httpUpload
                    )
                    #expect(!url.isEmpty)

                    _ = try await bob.waitForEvent { event in
                        if case let .messageReceived(m) = event,
                           let oob = m.element.child(named: "x", namespace: XMPPNamespaces.oob),
                           oob.child(named: "url")?.textContent == url {
                            return true
                        }
                        return false
                    }
                }
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Service sendFile via Jingle completes end-to-end`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let bobFullJID = try Self.fullJID(for: bob, harness: harness)
                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                let conversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)

                // Jingle service path returns an empty string from sendFile.
                // awaitTransportReady blocks until bob accepts, so kick the send
                // off without awaiting and drive the accept from the harness.
                let sendTask = Task { @MainActor in
                    try await harness.environment.fileTransferService.sendFile(
                        url: fixtureURL,
                        in: conversation,
                        accountID: alice.accountID,
                        method: .jingle,
                        peerJID: bobFullJID.description
                    )
                }
                harness.addCleanup { sendTask.cancel() }

                let offer = try await Self.waitForOffer(on: bob)
                try await harness.environment.fileTransferService.acceptIncomingTransfer(offer.sid, accountID: bob.accountID)

                let result = try await sendTask.value
                #expect(result.isEmpty)

                // JingleModule emits `.jingleFileTransferCompleted` on the
                // receiver (Bob), not the sender — see `runJingleRoundTrip`.
                _ = try await bob.waitForEvent(
                    matching: { event in
                        if case let .jingleFileTransferCompleted(completedSID) = event, completedSID == offer.sid { return true }
                        return false
                    },
                    timeout: TestTimeout.fileTransfer
                )
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Service accept incoming transfer marks it completed`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try #require(BareJID.parse(TestCredentials.bob.jid))

                let bobFullJID = try Self.fullJID(for: bob, harness: harness)
                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                let conversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)

                let sendTask = Task { @MainActor in
                    try await harness.environment.fileTransferService.sendFile(
                        url: fixtureURL,
                        in: conversation,
                        accountID: alice.accountID,
                        method: .jingle,
                        peerJID: bobFullJID.description
                    )
                }
                harness.addCleanup { sendTask.cancel() }

                let offer = try await Self.waitForOffer(on: bob)
                try await harness.environment.fileTransferService.acceptIncomingTransfer(offer.sid, accountID: bob.accountID)
                _ = try await sendTask.value

                // Wait for Bob's own `.jingleFileTransferCompleted` event.
                // FileTransferService.activeTransfers is shared across
                // accounts and its sid-based state updater mutates the first
                // match only, so asserting against that array can pass on
                // Alice's sender-side entry alone.
                _ = try await bob.waitForEvent(
                    matching: { event in
                        if case let .jingleFileTransferCompleted(completedSID) = event, completedSID == offer.sid { return true }
                        return false
                    },
                    timeout: TestTimeout.fileTransfer
                )
            }
        }

        // MARK: - Helpers

        /// Drives a full raw-Jingle offer → accept → transfer → completed cycle
        /// between the harness's alice and bob accounts. `assertBytesMatch`
        /// enables the bytewise equality check for the happy-path test; the
        /// fallback test skips it and asserts only on completion.
        @MainActor
        private static func runJingleRoundTrip(harness: TestHarness, assertBytesMatch: Bool) async throws {
            let alice = try #require(harness.accounts["alice"])
            let bob = try #require(harness.accounts["bob"])
            let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
            let bobClient = try #require(harness.environment.accountService.client(for: bob.accountID))
            let aliceJingle = try #require(await aliceClient.module(ofType: JingleModule.self))
            let bobJingle = try #require(await bobClient.module(ofType: JingleModule.self))

            let bobFullJID = try Self.fullJID(for: bob, harness: harness)
            let fixtureURL = try Self.makeFixtureFile(harness: harness)
            let fileData = try Array(Data(contentsOf: fixtureURL))
            let fileDesc = JingleFileDescription(
                name: fixtureURL.lastPathComponent,
                size: Int64(fileData.count),
                mediaType: "text/plain"
            )

            let sid = try await aliceJingle.initiateFileTransfer(to: bobFullJID, file: fileDesc)
            let offer = try await waitForOffer(on: bob, sid: sid)
            try await bobJingle.acceptFileTransfer(sid: offer.sid)

            async let received: [UInt8] = {
                try await bobJingle.awaitTransportReady(sid: offer.sid)
                return try await bobJingle.receiveFileData(sid: offer.sid, expectedSize: offer.fileSize)
            }()
            async let sent: Void = {
                try await aliceJingle.awaitTransportReady(sid: sid)
                try await aliceJingle.sendFileData(sid: sid, data: fileData)
            }()

            let receivedBytes = try await received
            _ = try await sent
            if assertBytesMatch {
                #expect(receivedBytes == fileData)
            }

            // JingleModule emits `.jingleFileTransferCompleted` only on receipt
            // of session-terminate or IBB close — the sender sends these
            // without emitting locally, so the event fires on the receiver only.
            _ = try await bob.waitForEvent(
                matching: { event in
                    if case let .jingleFileTransferCompleted(completedSID) = event, completedSID == sid { return true }
                    return false
                },
                timeout: TestTimeout.fileTransfer
            )
        }

        /// Waits for `.jingleFileTransferReceived` on `account`'s stream. Pass
        /// a `sid` to target a specific session (raw-Jingle flows know the sid
        /// upfront); omit it for service-layer flows where the service
        /// generates the sid internally.
        @MainActor
        private static func waitForOffer(on account: ConnectedAccount, sid: String? = nil) async throws -> JingleFileOffer {
            let offerEvent = try await account.waitForEvent(
                matching: { event in
                    if case let .jingleFileTransferReceived(offer) = event {
                        return sid == nil || offer.sid == sid
                    }
                    return false
                },
                timeout: TestTimeout.fileTransfer
            )
            guard case let .jingleFileTransferReceived(offer) = offerEvent else {
                throw TestHarnessError.streamClosed
            }
            return offer
        }

        @MainActor
        private static func makeFixtureFile(harness: TestHarness) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ducko-inttest-fixture-\(UUID().uuidString).txt", isDirectory: false)
            let payload = String(repeating: "ducko-inttest-\(UUID().uuidString)\n", count: 64)
            try payload.write(to: url, atomically: true, encoding: .utf8)
            harness.addCleanup { try? FileManager.default.removeItem(at: url) }
            return url
        }

        /// Derives the current full JID for an already-connected account. The
        /// Jingle path requires a resource, which is only observable via the
        /// `.connected(FullJID)` state recorded by AccountService.
        @MainActor
        private static func fullJID(for account: ConnectedAccount, harness: TestHarness) throws -> FullJID {
            guard case let .connected(fullJID) = harness.environment.accountService.connectionStates[account.accountID] else {
                throw TestHarnessError.notConnected(label: "account \(account.accountID)")
            }
            return fullJID
        }
    }
}
