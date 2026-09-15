import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

enum FileTransferServiceTests {
    private static func makeConversation(type: Conversation.ConversationType = .chat) -> Conversation {
        Conversation(
            id: UUID(),
            accountID: UUID(),
            jid: .parse("friend@example.com")!,
            type: type,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    @MainActor
    private static func failureReason(_ service: FileTransferService, sid: String) -> String? {
        guard case let .failed(reason) = service.activeTransfers.first(where: { $0.sid == sid })?.state else { return nil }
        return reason
    }

    @MainActor
    struct Initialization {
        @Test
        func `Starts with empty active transfers`() {
            let service = FileTransferService()
            #expect(service.activeTransfers.isEmpty)
        }
    }

    @MainActor
    struct SendFileErrors {
        @Test
        func `Throws fileReadFailed for missing file`() async throws {
            let service = FileTransferService()

            let conversation = makeConversation()

            let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID()).txt")
            do {
                try await service.sendFile(url: fakeURL, in: conversation, accountID: UUID())
                Issue.record("Expected fileReadFailed error")
            } catch let error as FileTransferService.FileTransferError {
                if case .fileReadFailed = error {
                    // Expected
                } else {
                    Issue.record("Expected fileReadFailed, got \(error)")
                }
            }
        }
    }

    @MainActor
    struct SendFileNoClient {
        @Test
        func `Throws noClient when no account service is set`() async throws {
            let service = FileTransferService()

            let conversation = makeConversation()

            // Create a real temp file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).txt")
            try "hello".write(to: tempURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            do {
                try await service.sendFile(url: tempURL, in: conversation, accountID: UUID())
                Issue.record("Expected noClient error")
            } catch let error as FileTransferService.FileTransferError {
                if case .noClient = error {
                    // Expected
                } else {
                    Issue.record("Expected noClient, got \(error)")
                }
            }
        }
    }

    @MainActor
    struct ActiveTransferTracking {
        @Test
        func `Transfer appears in activeTransfers during send attempt`() async throws {
            let service = FileTransferService()

            let conversation = makeConversation()

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).txt")
            try "test content".write(to: tempURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            // Will fail at noClient, but transfer should still be tracked
            _ = try? await service.sendFile(url: tempURL, in: conversation, accountID: UUID())

            #expect(service.activeTransfers.count == 1)
            let transfer = service.activeTransfers[0]
            #expect(transfer.fileName == tempURL.lastPathComponent)
            if case .failed = transfer.state {
                // Expected — failed due to no client
            } else {
                Issue.record("Expected failed state, got \(transfer.state)")
            }
        }
    }

    @MainActor
    struct TransferStateJingleCases {
        @Test
        func `Jingle transfer states can be pattern-matched`() {
            let states: [FileTransferService.TransferState] = [
                .negotiating,
                .connectingTransport,
                .transferring(progress: 0.5),
                .awaitingAcceptance,
                .completedTransfer
            ]

            for transferState in states {
                switch transferState {
                case .negotiating, .connectingTransport, .awaitingAcceptance, .completedTransfer:
                    break
                case let .transferring(progress):
                    #expect(progress == 0.5)
                case .requestingSlot, .uploading, .completed, .failed:
                    Issue.record("Unexpected HTTP state in Jingle test")
                }
            }
        }
    }

    @MainActor
    struct IncomingOfferTracking {
        @Test
        func `handleJingleEvent tracks incoming file offers`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(
                sid: "test-sid",
                from: peer,
                fileName: "document.pdf",
                fileSize: 5000,
                mediaType: "application/pdf"
            )

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: UUID())

            #expect(service.incomingOffers.count == 1)
            #expect(service.incomingOffers[0].sid == "test-sid")
            #expect(service.incomingOffers[0].fileName == "document.pdf")

            #expect(service.activeTransfers.count == 1)
            let transfer = service.activeTransfers[0]
            #expect(transfer.fileName == "document.pdf")
            #expect(transfer.method == .jingle)
            #expect(transfer.direction == .incoming)
            if case .awaitingAcceptance = transfer.state {
                // Expected
            } else {
                Issue.record("Expected awaitingAcceptance state")
            }
        }
    }

    @MainActor
    struct ContentAddTracking {
        @Test
        func `handleJingleEvent tracks content-add offers separately`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(
                sid: "session-1",
                from: peer,
                fileName: "extra.zip",
                fileSize: 2000,
                mediaType: "application/zip"
            )

            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-1", offer: offer), accountID: UUID())

            #expect(service.incomingOffers.isEmpty)
            #expect(service.incomingContentAddOffers.count == 1)
            #expect(service.incomingContentAddOffers[0].sid == "session-1")
            #expect(service.incomingContentAddOffers[0].contentName == "file-1")

            let transfer = service.activeTransfers.first { $0.sid == "session-1/file-1" }
            #expect(transfer != nil)
            #expect(transfer?.fileName == "extra.zip")
            if case .awaitingAcceptance = transfer?.state {
                // Expected
            } else {
                Issue.record("Expected awaitingAcceptance state")
            }
        }

        @Test
        func `Multiple content-adds on same session use unique composite IDs`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer1 = JingleFileOffer(sid: "session-1", from: peer, fileName: "file-a.txt", fileSize: 100)
            let offer2 = JingleFileOffer(sid: "session-1", from: peer, fileName: "file-b.txt", fileSize: 200)

            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-0", offer: offer1), accountID: UUID())
            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-1", offer: offer2), accountID: UUID())

            #expect(service.incomingContentAddOffers.count == 2)
            #expect(service.activeTransfers.count == 2)

            let sids = Set(service.activeTransfers.compactMap(\.sid))
            #expect(sids.contains("session-1/file-0"))
            #expect(sids.contains("session-1/file-1"))
        }

        @Test
        func `viewIncomingContentAddOffers projects correctly`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: "session-1", from: peer, fileName: "doc.pdf", fileSize: 3000, mediaType: "application/pdf")

            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-1", offer: offer), accountID: UUID())

            let viewOffers = service.viewIncomingContentAddOffers
            #expect(viewOffers.count == 1)
            #expect(viewOffers[0].id == "session-1/file-1")
            #expect(viewOffers[0].sid == "session-1")
            #expect(viewOffers[0].contentName == "file-1")
            #expect(viewOffers[0].fileName == "doc.pdf")
            #expect(viewOffers[0].fileSize == 3000)
            #expect(viewOffers[0].fromJIDString == "sender@example.com")
        }

        @Test
        func `Content rejected event removes offer and fails transfer`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: "session-1", from: peer, fileName: "file.txt", fileSize: 100)

            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-0", offer: offer), accountID: UUID())
            #expect(service.incomingContentAddOffers.count == 1)

            service.handleJingleEvent(.jingleContentRejected(sid: "session-1", contentName: "file-0"), accountID: UUID())
            #expect(service.incomingContentAddOffers.isEmpty)
            #expect(failureReason(service, sid: "session-1/file-0") == "The peer rejected the file")
        }

        @Test
        func `Content removed event removes offer and fails transfer`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: "session-1", from: peer, fileName: "file.txt", fileSize: 100)

            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-0", offer: offer), accountID: UUID())
            service.handleJingleEvent(.jingleContentRemoved(sid: "session-1", contentName: "file-0"), accountID: UUID())
            #expect(service.incomingContentAddOffers.isEmpty)
            #expect(failureReason(service, sid: "session-1/file-0") == "The peer removed the file")
        }

        @Test
        func `Session failure shows readable text on content-add transfers`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: "session-1", from: peer, fileName: "file.txt", fileSize: 100)

            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-0", offer: offer), accountID: UUID())
            service.handleJingleEvent(.jingleFileTransferFailed(sid: "session-1", reason: .decline), accountID: UUID())

            let transfer = service.activeTransfers.first { $0.sid == "session-1/file-0" }
            guard case let .failed(reason) = transfer?.state else {
                Issue.record("Expected failed state after session failure, got \(String(describing: transfer?.state))")
                return
            }
            #expect(reason == "The peer declined the transfer")
        }

        @Test
        func `Session completion completes content-add transfers`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: "session-1", from: peer, fileName: "file.txt", fileSize: 100)

            service.handleJingleEvent(.jingleContentAddReceived(sid: "session-1", contentName: "file-0", offer: offer), accountID: UUID())
            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "session-1", transport: .ibb), accountID: UUID())

            let transfer = service.activeTransfers.first { $0.sid == "session-1/file-0" }
            guard case .completedTransfer = transfer?.state else {
                Issue.record("Expected completed state after session completion, got \(String(describing: transfer?.state))")
                return
            }
            #expect(service.incomingContentAddOffers.isEmpty)
        }
    }

    @MainActor
    struct JingleProgressTracking {
        @Test
        func `handleJingleEvent updates transfer progress`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: "progress-sid", from: peer, fileName: "file.bin", fileSize: 1000)

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: UUID())
            service.handleJingleEvent(.jingleFileTransferProgress(sid: "progress-sid", bytesTransferred: 500, totalBytes: 1000), accountID: UUID())

            let transfer = service.activeTransfers.first { $0.sid == "progress-sid" }
            if case let .transferring(progress) = transfer?.state {
                #expect(progress == 0.5)
            } else {
                Issue.record("Expected transferring state with 0.5 progress")
            }
        }
    }

    struct ErrorDescriptions {
        @Test(arguments: [
            (FileTransferService.FileTransferError.fileReadFailed("No such file"), "Could not read the file: No such file"),
            (FileTransferService.FileTransferError.noClient, "Not connected to the server"),
            (FileTransferService.FileTransferError.noUploadModule, "File upload is not available"),
            (FileTransferService.FileTransferError.noJingleModule, "Direct file transfer is not available"),
            (FileTransferService.FileTransferError.uploadFailed("request too large"), "Upload failed: request too large"),
            (FileTransferService.FileTransferError.jingleFailed("Invalid recipient address: bob"), "File transfer failed: Invalid recipient address: bob"),
            (FileTransferService.FileTransferError.checksumMismatch(sid: "sid-1"), "The received file is corrupted"),
            (
                FileTransferService.FileTransferError.checksumUnsupportedAlgorithm(sid: "sid-1", algo: "sha-512"),
                "The received file cannot be verified (unsupported hash algorithm sha-512)"
            )
        ])
        func `FileTransferError renders a readable message`(error: FileTransferService.FileTransferError, expected: String) {
            let error: any Error = error
            #expect(error.localizedDescription == expected)
        }

        @Test(arguments: [(404, "Not found"), (413, "Request too large")])
        func `A failed upload's status reads as a capitalized phrase`(statusCode: Int, expected: String) {
            #expect(FileTransferService.uploadStatusText(statusCode) == expected)
        }
    }

    @MainActor
    struct JingleTerminateRace {
        private static func makeService(sid: String) throws -> FileTransferService {
            let service = FileTransferService()
            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: sid, from: peer, fileName: "file.bin", fileSize: 1000)
            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: UUID())
            return service
        }

        @Test
        func `Session cancellation after the terminate event keeps the terminate reason`() throws {
            let service = try Self.makeService(sid: "race-sid")

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .decline), accountID: UUID())
            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, sid: "race-sid")

            #expect(failureReason(service, sid: "race-sid") == "The peer declined the transfer")
        }

        @Test
        func `Terminate event after session cancellation overwrites with the terminate reason`() throws {
            let service = try Self.makeService(sid: "race-sid")

            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, sid: "race-sid")
            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .decline), accountID: UUID())

            #expect(failureReason(service, sid: "race-sid") == "The peer declined the transfer")
        }

        @Test
        func `Transport teardown after the terminate event keeps the terminate reason`() throws {
            let service = try Self.makeService(sid: "race-sid")

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .cancel), accountID: UUID())
            service.recordJingleTransferFailure(JingleModule.JingleError.transportFailed("The connection was closed"), sid: "race-sid")

            #expect(failureReason(service, sid: "race-sid") == "The transfer was canceled")
        }

        @Test
        func `A non-Jingle error after the terminate event is still recorded`() throws {
            let service = try Self.makeService(sid: "race-sid")
            let error = CocoaError(.fileReadNoSuchFile)

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .cancel), accountID: UUID())
            service.recordJingleTransferFailure(error, sid: "race-sid")

            #expect(failureReason(service, sid: "race-sid") == error.localizedDescription)
        }

        @Test
        func `An integrity failure after the terminate event is still recorded`() throws {
            let service = try Self.makeService(sid: "race-sid")

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .cancel), accountID: UUID())
            service.recordJingleTransferFailure(FileTransferService.FileTransferError.checksumMismatch(sid: "race-sid"), sid: "race-sid")

            #expect(failureReason(service, sid: "race-sid") == "The received file is corrupted")
        }

        @Test
        func `Session cancellation without a failure event records the error`() throws {
            let service = try Self.makeService(sid: "race-sid")

            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, sid: "race-sid")

            #expect(failureReason(service, sid: "race-sid") == "The file transfer session was not found")
        }
    }

    @MainActor
    struct JingleCompletionTracking {
        @Test
        func `handleJingleEvent transitions to completedTransfer on completion`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(sid: "complete-sid", from: peer, fileName: "file.bin", fileSize: 1000)

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: UUID())
            #expect(service.activeTransfers.count == 1)
            #expect(service.incomingOffers.count == 1)

            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "complete-sid", transport: .socks5), accountID: UUID())

            let transfer = service.activeTransfers.first { $0.sid == "complete-sid" }
            if case .completedTransfer = transfer?.state {
                // Expected
            } else {
                Issue.record("Expected completedTransfer state, got \(String(describing: transfer?.state))")
            }
            #expect(service.incomingOffers.isEmpty)
        }
    }

    @MainActor
    struct JingleTaskFailureRecording {
        private static let peerJID = "bob@example.com/res"

        private struct Harness {
            let accountService: AccountService
            let service: FileTransferService
            let transport: MockTransport
            let accountID: UUID
            let connectTask: Task<Void, any Error>
        }

        private static func connect() async throws -> Harness {
            let store = MockPersistenceStore()
            let account = try Account(
                id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date()
            )
            await store.addAccount(account)
            let transport = MockTransport()
            let accountService = makeAccountService(
                store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [JingleModule()])
            )
            try await accountService.loadAccounts()
            let service = FileTransferService()
            service.setAccountService(accountService)
            // Only offers and requests are forwarded: each test replays the failure event itself, so it lands before
            // the transfer task's catch runs.
            accountService.onEvent = { [weak service] event, accountID in
                if case .jingleFileTransferReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
                if case .jingleFileRequestReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
            }
            let (_, connectTask) = try await driveMockConnect(accountService, accountID: account.id, transport: transport)
            return Harness(accountService: accountService, service: service, transport: transport, accountID: account.id, connectTask: connectTask)
        }

        private static func tearDown(_ harness: Harness) async {
            harness.connectTask.cancel()
            await harness.accountService.disconnectAll()
        }

        private static func sessionInitiateXML(sid: String, senders: String, size: Int = 3) -> String {
            """
            <iq type='set' id='initiate-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(peerJID)'>\
            <content creator='initiator' name='a-file-offer' senders='\(senders)'>\
            <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>test.txt</name><size>\(size)</size></file></description>\
            <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
            </content>\
            </jingle>\
            </iq>
            """
        }

        private static func transportReplaceXML(sid: String) -> String {
            """
            <iq type='set' id='replace-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='transport-replace' sid='\(sid)'>\
            <content creator='initiator' name='a-file-offer'>\
            <transport xmlns='urn:xmpp:jingle:transports:ibb:1' sid='ibb-\(sid)' block-size='4096'/>\
            </content>\
            </jingle>\
            </iq>
            """
        }

        private static func declineXML(sid: String) -> String {
            """
            <iq type='set' id='terminate-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='\(sid)'><reason><decline/></reason></jingle>\
            </iq>
            """
        }

        private static func poll(_ condition: () -> Bool) async throws {
            for _ in 0 ..< 100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// Replays the peer's decline event, then delivers the decline stanza that fails the transfer task's wait.
        private static func deliverDecline(_ harness: Harness, sid: String) async {
            harness.service.handleJingleEvent(.jingleFileTransferFailed(sid: sid, reason: .decline), accountID: harness.accountID)
            await harness.transport.simulateReceive(declineXML(sid: sid))
        }

        /// Takes the one transfer task the test started. Taken before the stanza that ends it, which could otherwise let
        /// the task finish and remove itself first.
        private static func takeTransferTask(_ service: FileTransferService) -> [Task<Void, Never>] {
            let tasks = service.takePendingTasks()
            #expect(tasks.count == 1)
            return tasks
        }

        /// Waits for the taken transfer tasks; a task that never finishes fails the test instead of hanging it.
        private static func drain(_ tasks: [Task<Void, Never>]) async throws {
            let outcome = try await boundedOutcome {
                for task in tasks {
                    await task.value
                }
            }
            #expect(outcome != nil)
        }

        @Test
        func `An accepted transfer keeps the decline after its transport wait fails`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "accept-sid", senders: "initiator"))
            try await Self.poll { !harness.service.incomingOffers.isEmpty }

            try await harness.service.acceptIncomingTransfer("accept-sid", accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            await Self.deliverDecline(harness, sid: "accept-sid")
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "accept-sid") == "The peer declined the transfer")
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer records a new failure after its transport recovers`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "recover-sid", senders: "initiator", size: 0))
            try await Self.poll { !harness.service.incomingOffers.isEmpty }

            try await harness.service.acceptIncomingTransfer("recover-sid", accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            harness.service.handleJingleEvent(.jingleFileTransferFailed(sid: "recover-sid", reason: .connectivityError), accountID: harness.accountID)
            await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "recover-sid"))
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "recover-sid") == "File transfer failed: The file size is invalid")
            await Self.tearDown(harness)
        }

        @Test
        func `A fulfilled request keeps the decline after its transport wait fails`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "fulfill-sid", senders: "responder"))
            try await Self.poll { !harness.service.incomingRequests.isEmpty }

            try await harness.service.fulfillFileRequest("fulfill-sid", fileData: [1, 2, 3], accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            await Self.deliverDecline(harness, sid: "fulfill-sid")
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "fulfill-sid") == "The peer declined the transfer")
            await Self.tearDown(harness)
        }

        @Test
        func `A sent transfer keeps the decline after its transport wait fails`() async throws {
            let harness = try await Self.connect()
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("jingle-\(UUID()).txt")
            try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let service = harness.service
            let accountID = harness.accountID
            let sendTask = Task {
                try await service.sendFile(url: fileURL, in: makeConversation(), accountID: accountID, method: .jingle, peerJID: Self.peerJID)
            }

            // Proxy discovery queries the server before the session-initiate goes out; answer with no items.
            let discoItems = try #require(await harness.transport.waitForSent(matching: { $0.contains("disco#items") }))
            let discoID = try #require(discoItems.firstMatch(of: /id=["']([^"']+)["']/)?.output.1)
            await harness.transport.simulateReceive(
                "<iq type='result' id='\(discoID)' from='example.com'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>"
            )
            try await Self.poll { harness.service.activeTransfers.contains { $0.method == .jingle } }
            let sid = try #require(harness.service.activeTransfers.first { $0.method == .jingle }?.sid)

            await Self.deliverDecline(harness, sid: sid)
            let outcome = try await boundedOutcome { _ = try? await sendTask.value }
            #expect(outcome != nil)

            #expect(failureReason(harness.service, sid: sid) == "The peer declined the transfer")
            await Self.tearDown(harness)
        }
    }
}
