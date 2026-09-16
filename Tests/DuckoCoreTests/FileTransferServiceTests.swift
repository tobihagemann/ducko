import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

enum FileTransferServiceTests {
    private static let testAccountID = UUID()

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

    private static func isOfferNotFound(_ error: FileTransferService.FileTransferError?) -> Bool {
        if case .offerNotFound? = error { true } else { false }
    }

    @MainActor
    private static func failureReason(_ service: FileTransferService, sid: String) -> String? {
        guard case let .failed(reason) = service.activeTransfers.first(where: { $0.sid == sid })?.state else { return nil }
        return reason
    }

    @MainActor
    private static func failureReason(_ service: FileTransferService, rowID: UUID) -> String? {
        guard case let .failed(reason) = service.activeTransfers.first(where: { $0.id == rowID })?.state else { return nil }
        return reason
    }

    /// Puts an accepted incoming Jingle transfer's row in `service` under `sid` and returns its id. A Jingle offer only
    /// gets a row once the user accepts it, which needs a session, so the rules that act on an existing row start here.
    @MainActor
    @discardableResult
    private static func seedJingleRow(_ service: FileTransferService, sid: String, accountID: UUID = testAccountID) -> UUID {
        let id = UUID()
        service.registerTransferForTesting(.init(
            id: id, accountID: accountID, fileName: "file.bin", fileSize: 1, state: .connectingTransport, method: .jingle,
            direction: .incoming, sid: sid
        ))
        return id
    }

    /// Delivers an OOB offer with stanza id `id` to `service`, which gives it a waiting row.
    @MainActor
    private static func seedOOBOffer(
        _ service: FileTransferService, id: String, offerID: String, accountID: UUID = testAccountID
    ) throws {
        let peer = try #require(FullJID.parse("sender@example.com/res"))
        let offer = OOBIQOffer(offerID: offerID, id: id, from: .full(peer), url: "https://example.com/file.bin", desc: nil)
        service.handleJingleEvent(.oobIQOfferReceived(offer), accountID: accountID)
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
                try await service.sendFile(url: fakeURL, in: conversation, accountID: testAccountID)
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
                try await service.sendFile(url: tempURL, in: conversation, accountID: testAccountID)
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
            _ = try? await service.sendFile(url: tempURL, in: conversation, accountID: testAccountID)

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
                case .negotiating, .connectingTransport, .awaitingAcceptance, .completedTransfer, .received:
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
                offerID: "test-offer",
                sid: "test-sid",
                from: peer,
                fileName: "document.pdf",
                fileSize: 5000,
                mediaType: "application/pdf"
            )

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)

            #expect(service.incomingOffers.count == 1)
            #expect(service.incomingOffers[0].offer.sid == "test-sid")
            #expect(service.incomingOffers[0].offer.fileName == "document.pdf")
            #expect(service.incomingOffers[0].accountID == testAccountID)

            // The row belongs to the accepted transfer, so an offer still waiting on the user has none.
            #expect(service.activeTransfers.isEmpty)
        }
    }

    @MainActor
    struct StickyFailure {
        private static func makeFailedService(sid: String) throws -> FileTransferService {
            let service = FileTransferService()
            seedJingleRow(service, sid: sid)
            service.handleJingleEvent(.jingleFileTransferFailed(sid: sid, reason: .checksumMismatch), accountID: testAccountID)
            return service
        }

        @Test
        func `A failed row stays failed after a later progress event`() throws {
            let service = try Self.makeFailedService(sid: "sticky-sid")
            service.handleJingleEvent(.jingleFileTransferProgress(sid: "sticky-sid", bytesTransferred: 500, totalBytes: 1000), accountID: testAccountID)
            #expect(failureReason(service, sid: "sticky-sid") == "The received file is corrupted")
        }

        @Test
        func `A failed row stays failed after a later completion event`() throws {
            let service = try Self.makeFailedService(sid: "sticky-sid")
            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "sticky-sid", transport: .ibb), accountID: testAccountID)
            #expect(failureReason(service, sid: "sticky-sid") == "The received file is corrupted")
        }

        /// A session reports its end once. A row whose session did must not take a later session's outcome just because
        /// the peer reused the sid.
        @Test
        func `A row whose session ended keeps its outcome when the sid is reused`() throws {
            let service = try Self.makeFailedService(sid: "sticky-sid")
            let live = seedJingleRow(service, sid: "sticky-sid")
            service.handleJingleEvent(.jingleFileTransferFailed(sid: "sticky-sid", reason: .decline), accountID: testAccountID)
            #expect(failureReason(service, sid: "sticky-sid") == "The received file is corrupted")
            #expect(failureReason(service, rowID: live) == "The peer declined the transfer")
        }
    }

    struct LinkFileName {
        /// A peer picks the link, and its last component is percent-decoded before it is shown or saved.
        @Test(arguments: [
            ("https://example.com/invoice%E2%80%AEfdp.app", "invoicefdp.app"),
            ("https://example.com/%1B%5B31mred.txt", "[31mred.txt"),
            ("https://example.com/..%2F..%2Fevil.sh", "evil.sh"),
            ("https://example.com/report.pdf", "report.pdf")
        ])
        func `A link's file name is reduced to one visible name`(link: String, expected: String) {
            #expect(Attachment.fileName(forLink: link) == expected)
        }
    }

    @MainActor
    struct OfferOrdering {
        /// Bare `/accept` takes the last offer as the newest, so both kinds have to share one arrival order.
        @Test(arguments: [true, false])
        func `Waiting offers are ordered by arrival across both kinds`(linkFirst: Bool) async throws {
            let service = FileTransferService()
            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let link = XMPPEvent.oobIQOfferReceived(
                OOBIQOffer(offerID: "link-offer", id: "link-id", from: .full(peer), url: "https://example.com/a.bin", desc: nil)
            )
            let file = XMPPEvent.jingleFileTransferReceived(
                JingleFileOffer(offerID: "file-offer", sid: "file-sid", from: peer, fileName: "b.bin", fileSize: 1)
            )

            service.handleJingleEvent(linkFirst ? link : file, accountID: testAccountID)
            try await Task.sleep(for: .milliseconds(5))
            service.handleJingleEvent(linkFirst ? file : link, accountID: testAccountID)

            #expect(service.viewIncomingOffers.map(\.offerID) == (linkFirst ? ["link-offer", "file-offer"] : ["file-offer", "link-offer"]))
        }
    }

    @MainActor
    struct AccountScopedRows {
        @Test
        func `A session's events update only the row of the account they arrived on`() {
            let service = FileTransferService()
            let otherAccountID = UUID()
            seedJingleRow(service, sid: "shared-sid", accountID: otherAccountID)
            seedJingleRow(service, sid: "shared-sid", accountID: testAccountID)

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "shared-sid", reason: .decline), accountID: testAccountID)

            let other = service.activeTransfers.first { $0.accountID == otherAccountID }
            guard case .connectingTransport? = other?.state else {
                Issue.record("Expected the other account's row to stay connecting, got \(String(describing: other?.state))")
                return
            }
            let own = service.activeTransfers.first { $0.accountID == testAccountID }
            guard case .failed("The peer declined the transfer")? = own?.state else {
                Issue.record("Expected the own row to fail, got \(String(describing: own?.state))")
                return
            }
        }

        /// The OOB branch answers before the Jingle lookup is ever reached, so its own account check is the only thing
        /// between an offer and an accept given on another account.
        @Test
        func `Accepting an OOB offer on another account does not find it`() async throws {
            let service = FileTransferService()
            let otherAccountID = UUID()
            try seedOOBOffer(service, id: "shared-oob", offerID: "offer-oob", accountID: otherAccountID)

            // Not found at all: with the account left out of the lookup, the OOB branch would take the other account's
            // offer and fail later, on that account's missing client, instead.
            let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await service.acceptIncomingTransfer("offer-oob", accountID: testAccountID)
            }
            #expect(isOfferNotFound(error))

            let other = service.activeTransfers.first { $0.accountID == otherAccountID }
            guard case .awaitingAcceptance? = other?.state else {
                Issue.record("Expected the other account's offer to be untouched, got \(String(describing: other?.state))")
                return
            }
        }

        /// Accepting looks the offer up by offer id *and* account, so one account cannot answer for another's transfer.
        @Test
        func `Accepting an offer on another account does not find it`() async throws {
            let service = FileTransferService()
            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(offerID: "offer-shared", sid: "shared-sid", from: peer, fileName: "file.bin", fileSize: 1)
            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)
            #expect(service.incomingOffers.count == 1)

            let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await service.acceptIncomingTransfer("offer-shared", accountID: UUID())
            }
            #expect(isOfferNotFound(error))
            // The offer the other account could not take is still waiting for the one it arrived on.
            #expect(service.incomingOffers.count == 1)
        }
    }

    @MainActor
    struct JingleEventRouting {
        /// A peer can reuse a sid once its session ended, so a finished row under that sid belongs to the earlier session
        /// and an event for the live one must not rewrite it.
        @Test
        func `An event updates the live row, not a finished one under the same sid`() {
            let service = FileTransferService()
            let finished = seedJingleRow(service, sid: "reused-sid")
            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "reused-sid", transport: .ibb), accountID: testAccountID)
            let live = seedJingleRow(service, sid: "reused-sid")

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "reused-sid", reason: .decline), accountID: testAccountID)

            guard case .completedTransfer? = service.activeTransfers.first(where: { $0.id == finished })?.state else {
                Issue.record("Expected the earlier session's row to stay completed")
                return
            }
            guard case .failed("The peer declined the transfer")? = service.activeTransfers.first(where: { $0.id == live })?.state else {
                Issue.record("Expected the live row to fail")
                return
            }
        }

        /// A link offer's row carries the peer's stanza id, which a Jingle sid can equal. A Jingle event is not about it.
        @Test
        func `A Jingle event under a link offer's id leaves that offer's row alone`() throws {
            let service = FileTransferService()
            try seedOOBOffer(service, id: "oob-1", offerID: "offer-oob-1")
            let control = seedJingleRow(service, sid: "oob-1")

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "oob-1", reason: .cancel), accountID: testAccountID)

            // The event did land on a row, so the link row staying put is not an event that went nowhere.
            #expect(failureReason(service, rowID: control) == "The transfer was canceled")
            guard case .awaitingAcceptance? = service.activeTransfers.first(where: { $0.method == .httpUpload })?.state else {
                Issue.record("Expected the link offer's row to keep waiting")
                return
            }
        }
    }

    struct DownloadFraming {
        private static func downloadsFolder() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("framing-downloads-\(UUID())", isDirectory: true)
        }

        private static func downloadFailure(_ response: LoopbackHTTPServer.Response) async throws -> String? {
            let server = try #require(LoopbackHTTPServer(responses: [response]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await FileTransferService.downloadRemoteFile(from: server.url(), named: "file.bin", into: directory)
                return nil
            } catch {
                #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
                return error.localizedDescription
            }
        }

        /// A body whose end is only the connection closing, or a chunked body cut off at a chunk boundary, ends like a
        /// whole one, so without a declared length nothing tells a truncated file from a complete one.
        @Test(arguments: [
            LoopbackHTTPServer.Response.Framing.chunked(terminated: false),
            .chunked(terminated: true),
            .closeDelimited
        ])
        func `A body with no declared length is not kept`(framing: LoopbackHTTPServer.Response.Framing) async throws {
            let failure = try await Self.downloadFailure(.init(status: 200, body: [1, 2, 3], framing: framing))
            #expect(failure == "Could not download the file: The server did not provide a file size")
        }

        @Test
        func `A body shorter than its declared length is not kept`() async throws {
            let failure = try await Self.downloadFailure(.init(status: 200, body: [1, 2, 3], framing: .declaredLength(10)))
            #expect(failure != nil)
        }

        /// A declared length counts the encoded bytes, so an encoded body cannot be checked against it once decoded.
        @Test
        func `A body in an encoding is not kept`() async throws {
            let failure = try await Self.downloadFailure(.init(status: 200, body: [1, 2, 3], extraHeaders: ["Content-Encoding: x-test"]))
            #expect(failure == "Could not download the file: The server sent the file in a form whose size cannot be checked")
        }

        /// A server that ignores the request for an unencoded body and compresses it anyway: URLSession decodes such a body
        /// on arrival, so its declared length no longer counts the bytes that arrive.
        @Test
        func `A gzip-encoded body is not kept`() async throws {
            // "ducko " repeated 400 times, gzip-compressed.
            let gzipBody: [UInt8] = [
                0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0x4B, 0x29, 0x4D, 0xCE, 0xCE, 0x57, 0x48, 0x19, 0x25, 0x47,
                0xC9, 0x51, 0x72, 0x94, 0x1C, 0x25, 0x47, 0xC9, 0x51, 0x72, 0x94, 0x1C, 0x25, 0xA9, 0x44, 0x02, 0x00, 0x88, 0xBE, 0x2A,
                0x21, 0x60, 0x09, 0x00, 0x00
            ]
            let failure = try await Self.downloadFailure(.init(status: 200, body: gzipBody, extraHeaders: ["Content-Encoding: gzip"]))
            #expect(failure == "Could not download the file: The server sent the file in a form whose size cannot be checked")
        }

        /// A body longer than one write chunk crosses the chunk boundary, where each full chunk is written and counted, and
        /// ends in a partial chunk.
        @Test
        func `A body spanning several write chunks is kept whole`() async throws {
            let body = (0 ..< (2 * 64 * 1024 + 7)).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) }
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: body)]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }

            let download = try await FileTransferService.downloadRemoteFile(from: server.url(), named: "large.bin", into: directory)

            #expect(download.byteCount == Int64(body.count))
            #expect(try Data(contentsOf: download.fileURL) == Data(body))
        }

        @Test
        func `A body of its declared length is kept, asked for without an encoding`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [1, 2, 3])]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }

            let download = try await FileTransferService.downloadRemoteFile(from: server.url(), named: "file.bin", into: directory)

            #expect(download.byteCount == 3)
            #expect(try Data(contentsOf: download.fileURL) == Data([1, 2, 3]))
            #expect(server.requests.first?.lowercased().contains("accept-encoding: identity") == true)
        }
    }

    struct ReceivedFiles {
        @Test
        func `A saved file takes the next free name and is quarantined`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jingle-downloads-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = try await FileTransferService.saveReceivedFile([1, 2, 3], named: "notes.txt", in: directory)
            let second = try await FileTransferService.saveReceivedFile([4], named: "notes.txt", in: directory)

            #expect(first.lastPathComponent == "notes.txt")
            #expect(second.lastPathComponent == "notes 2.txt")
            #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
            #expect(try Data(contentsOf: second) == Data([4]))
            #expect(try second.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
        }

        @Test
        func `A name with no extension is numbered without a trailing dot`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jingle-downloads-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = try await FileTransferService.saveReceivedFile([1], named: "README", in: directory)
            let second = try await FileTransferService.saveReceivedFile([2], named: "README", in: directory)

            #expect(first.lastPathComponent == "README")
            #expect(second.lastPathComponent == "README 2")
        }

        /// The name reaches this writer from a peer, and `appending(path:)` honours separators, so containment rests on
        /// the reduction rather than on the caller.
        @Test(arguments: [
            ("../escaped.txt", "escaped.txt"),
            ("../../deeper.txt", "deeper.txt"),
            ("sub/dir/inner.txt", "inner.txt"),
            ("..", "unnamed"),
            (".hidden", "hidden"),
            ("", "unnamed")
        ])
        func `A peer's name cannot place the file outside its directory`(name: String, expected: String) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jingle-downloads-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let saved = try await FileTransferService.saveReceivedFile([1], named: name, in: directory)

            #expect(saved.lastPathComponent == expected)
            #expect(saved.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        }
    }

    @MainActor
    struct JingleProgressTracking {
        @Test
        func `Progress for an offer nobody accepted moves no row and invents none`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(offerID: "progress-offer", sid: "progress-sid", from: peer, fileName: "file.bin", fileSize: 1000)

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)
            // Armed before the progress event: without this the empty-rows assertion below also holds when offer
            // tracking stopped working altogether.
            #expect(service.incomingOffers.count == 1)

            service.handleJingleEvent(.jingleFileTransferProgress(sid: "progress-sid", bytesTransferred: 500, totalBytes: 1000), accountID: testAccountID)

            // Progress for an offer nobody accepted has no row to move, and must not invent one.
            #expect(service.activeTransfers.isEmpty)
        }
    }

    struct ErrorDescriptions {
        @Test(arguments: [
            (FileTransferService.FileTransferError.fileReadFailed("No such file"), "Could not read the file: No such file"),
            (FileTransferService.FileTransferError.fileSaveFailed("Disk full"), "Could not save the file: Disk full"),
            (FileTransferService.FileTransferError.offerNotFound, "The file offer is no longer waiting"),
            (FileTransferService.FileTransferError.noClient, "Not connected to the server"),
            (FileTransferService.FileTransferError.noUploadModule, "File upload is not available"),
            (FileTransferService.FileTransferError.noJingleModule, "Direct file transfer is not available"),
            (FileTransferService.FileTransferError.uploadFailed("request too large"), "Upload failed: request too large"),
            (FileTransferService.FileTransferError.jingleFailed("Invalid recipient address: bob"), "File transfer failed: Invalid recipient address: bob")
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
        private static func makeService() -> (FileTransferService, UUID) {
            let service = FileTransferService()
            return (service, seedJingleRow(service, sid: "race-sid"))
        }

        @Test
        func `Session cancellation after the terminate event keeps the terminate reason`() {
            let (service, rowID) = Self.makeService()

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .decline), accountID: testAccountID)
            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, id: rowID)

            #expect(failureReason(service, rowID: rowID) == "The peer declined the transfer")
        }

        @Test
        func `Terminate event after session cancellation overwrites with the terminate reason`() {
            let (service, rowID) = Self.makeService()

            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, id: rowID)
            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .decline), accountID: testAccountID)

            #expect(failureReason(service, rowID: rowID) == "The peer declined the transfer")
        }

        @Test
        func `Transport teardown after the terminate event keeps the terminate reason`() {
            let (service, rowID) = Self.makeService()

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .cancel), accountID: testAccountID)
            service.recordJingleTransferFailure(JingleModule.JingleError.transportFailed("The connection was closed"), id: rowID)

            #expect(failureReason(service, rowID: rowID) == "The transfer was canceled")
        }

        @Test
        func `A non-Jingle error after the terminate event is still recorded`() {
            let (service, rowID) = Self.makeService()
            let error = CocoaError(.fileReadNoSuchFile)

            service.handleJingleEvent(.jingleFileTransferFailed(sid: "race-sid", reason: .cancel), accountID: testAccountID)
            service.recordJingleTransferFailure(error, id: rowID)

            #expect(failureReason(service, rowID: rowID) == error.localizedDescription)
        }

        @Test
        func `Session cancellation without a failure event records the error`() {
            let (service, rowID) = Self.makeService()

            service.recordJingleTransferFailure(JingleModule.JingleError.sessionNotFound, id: rowID)

            #expect(failureReason(service, rowID: rowID) == "The file transfer session was not found")
        }
    }

    @MainActor
    struct JingleCompletionTracking {
        @Test
        func `An offer the peer completes before it is accepted leaves nothing behind`() throws {
            let service = FileTransferService()

            let peer = try #require(FullJID.parse("sender@example.com/res"))
            let offer = JingleFileOffer(offerID: "complete-offer", sid: "complete-sid", from: peer, fileName: "file.bin", fileSize: 1000)

            service.handleJingleEvent(.jingleFileTransferReceived(offer), accountID: testAccountID)
            #expect(service.incomingOffers.count == 1)

            service.handleJingleEvent(.jingleFileTransferCompleted(sid: "complete-sid", transport: .socks5), accountID: testAccountID)

            #expect(service.incomingOffers.isEmpty)
            #expect(service.activeTransfers.isEmpty)
        }
    }

    @MainActor
    struct JingleTaskFailureRecording {
        private static let peerJID = "bob@example.com/res"

        private struct Harness {
            let accountService: AccountService
            let store: MockPersistenceStore
            let chatService: ChatService
            let service: FileTransferService
            let transport: MockTransport
            let accountID: UUID
            let connectTask: Task<Void, any Error>
        }

        private static func connect(downloadsDirectory: URL = FileManager.default.temporaryDirectory) async throws -> Harness {
            let store = MockPersistenceStore()
            let account = try Account(
                id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date()
            )
            await store.addAccount(account)
            let transport = MockTransport()
            let accountService = makeAccountService(
                store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [JingleModule(), OOBModule()])
            )
            try await accountService.loadAccounts()
            let chatService = ChatService(store: store, transcripts: MockTranscriptStore(), filterPipeline: MessageFilterPipeline())
            let service = FileTransferService(downloadsDirectory: downloadsDirectory)
            service.setAccountService(accountService)
            service.setChatService(chatService)
            // Only offers are forwarded: each test replays the failure event itself, so it lands before the transfer
            // task's catch runs.
            accountService.onEvent = { [weak service] event, accountID in
                if case .jingleFileTransferReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
                if case .oobIQOfferReceived = event { service?.handleJingleEvent(event, accountID: accountID) }
            }
            let (_, connectTask) = try await driveMockConnect(accountService, accountID: account.id, transport: transport)
            return Harness(
                accountService: accountService, store: store, chatService: chatService, service: service,
                transport: transport, accountID: account.id, connectTask: connectTask
            )
        }

        private static func tearDown(_ harness: Harness) async {
            harness.connectTask.cancel()
            await harness.accountService.disconnectAll()
        }

        private static func sessionInitiateXML(sid: String, size: Int = 3) -> String {
            """
            <iq type='set' id='initiate-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(peerJID)'>\
            <content creator='initiator' name='a-file-offer'>\
            <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>test.txt</name><size>\(size)</size></file></description>\
            <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
            </content>\
            </jingle>\
            </iq>
            """
        }

        private static func transportReplaceXML(sid: String, ibbSID: String? = nil) -> String {
            """
            <iq type='set' id='replace-\(sid)' from='\(peerJID)'>\
            <jingle xmlns='urn:xmpp:jingle:1' action='transport-replace' sid='\(sid)'>\
            <content creator='initiator' name='a-file-offer'>\
            <transport xmlns='urn:xmpp:jingle:transports:ibb:1' sid='\(ibbSID ?? "ibb-\(sid)")' block-size='4096'/>\
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

        /// Waits for the offer the peer sent under `wireID` — a Jingle sid or an OOB stanza id — and returns the id this
        /// side gave it.
        private static func waitForOffer(_ harness: Harness, wireID: String, from sender: String? = nil) async throws -> String {
            func lookUp() -> String? {
                harness.service.incomingOffers.first { $0.offer.sid == wireID }?.offer.offerID
                    ?? harness.service.incomingOOBOffers.first { pending in
                        pending.offer.id == wireID && (sender == nil || pending.offer.from.description == sender)
                    }?.offer.offerID
            }
            try await poll { lookUp() != nil }
            return try #require(lookUp())
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
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "accept-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "accept-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            await Self.deliverDecline(harness, sid: "accept-sid")
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "accept-sid") == "The peer declined the transfer")
            await Self.tearDown(harness)
        }

        @Test
        func `A failed accepted transfer keeps its first failure`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "recover-sid", size: 0))
            let offerID = try await Self.waitForOffer(harness, wireID: "recover-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            harness.service.handleJingleEvent(.jingleFileTransferFailed(sid: "recover-sid", reason: .connectivityError), accountID: harness.accountID)
            await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "recover-sid"))
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "recover-sid") == "The peer could not be reached")
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer of an empty file records the invalid size`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "empty-sid", size: 0))
            let offerID = try await Self.waitForOffer(harness, wireID: "empty-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)
            await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "empty-sid"))
            try await Self.drain(tasks)

            #expect(failureReason(harness.service, sid: "empty-sid") == "File transfer failed: The file size is invalid")
            await Self.tearDown(harness)
        }

        /// Accepting a link reports a saved file only once it was fetched. A `file:` URL is refused before any request goes
        /// out, which makes that observable without a network round trip.
        @Test
        func `An OOB offer this side cannot retrieve reports no completion`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(
                "<iq type='set' id='oob-local' from='\(Self.peerJID)'><query xmlns='jabber:iq:oob'><url>file:///etc/passwd</url></query></iq>"
            )
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-local")

            await #expect(throws: (any Error).self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }

            let row = harness.service.activeTransfers.first { $0.sid == "oob-local" }
            #expect(row != nil)
            if case .received = row?.state { Issue.record("A link that was never fetched reported a saved file") }
            if case .completedTransfer = row?.state { Issue.record("A link that was never fetched reported a completion") }
            await Self.tearDown(harness)
        }

        private static func oobOfferXML(id: String, url: URL) -> String {
            oobOfferXML(id: id, url: url, from: peerJID)
        }

        /// Whether this side answered the peer's OOB request `id` with a result.
        private static func answeredOffer(_ harness: Harness, id: String) async -> Bool {
            await harness.transport.sentBytes.contains { bytes in
                let stanza = String(decoding: bytes, as: UTF8.self)
                return stanza.contains(id) && stanza.contains("result")
            }
        }

        private static func downloadsFolder() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("oob-downloads-\(UUID())", isDirectory: true)
        }

        @Test
        func `An accepted OOB offer is downloaded, saved and recorded before it is answered`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [1, 2, 3])]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-ok", url: server.url()))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-ok")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)

            let row = harness.service.activeTransfers.first { $0.sid == "oob-ok" }
            guard case let .received(fileURL)? = row?.state else {
                Issue.record("Expected a received row, got \(String(describing: row?.state))")
                await Self.tearDown(harness)
                return
            }
            #expect(try Data(contentsOf: fileURL) == Data([1, 2, 3]))
            #expect(fileURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
            let conversation = try #require(try await harness.store.fetchConversations(for: harness.accountID).first)
            let message = try #require(await harness.chatService.loadMessages(for: conversation.id).first)
            #expect(message.attachments.first?.origin == .locallySaved)
            #expect(!harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
            #expect(await Self.answeredOffer(harness, id: "oob-ok"))
            await Self.tearDown(harness)
        }

        // A download that fails leaves the offer where the user can accept it again, answers nothing, and lets that retry
        // finish: the row returns to waiting rather than to a failure a later success could not replace.
        @Test
        func `A refused OOB download keeps the offer, answers nothing, and a retry succeeds`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 404, body: Array("gone".utf8)), .init(status: 200, body: [7, 8])]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-retry", url: server.url()))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-retry")

            await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }
            #expect(harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
            #expect(await !Self.answeredOffer(harness, id: "oob-retry"))
            #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
            guard case .awaitingAcceptance? = harness.service.activeTransfers.first(where: { $0.sid == "oob-retry" })?.state else {
                Issue.record("Expected the row to wait again after the refused download")
                await Self.tearDown(harness)
                return
            }

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            guard case let .received(fileURL)? = harness.service.activeTransfers.first(where: { $0.sid == "oob-retry" })?.state else {
                Issue.record("Expected the retried download to be received")
                await Self.tearDown(harness)
                return
            }
            #expect(try Data(contentsOf: fileURL) == Data([7, 8]))
            await Self.tearDown(harness)
        }

        /// A 206 answers a range this side never asked for, and its body is only part of the resource.
        @Test
        func `A partial response is not kept as the file`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 206, body: [1, 2])]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-partial", url: server.url()))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-partial")

            await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }
            #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true)
            await Self.tearDown(harness)
        }

        /// While a download runs the offer is claimed, so neither a decline nor a second accept can act on it.
        @Test
        func `An OOB offer being downloaded cannot be declined or accepted again`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [4, 5, 6])]))
            defer { server.stop() }
            server.hold()
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-busy", url: server.url()))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-busy")

            let service = harness.service
            let accountID = harness.accountID
            let accept = Task { try await service.acceptIncomingTransfer(offerID, accountID: accountID) }
            try await Self.poll { !service.viewIncomingOffers.contains { $0.offerID == offerID } }
            #expect(!service.viewIncomingOffers.contains { $0.offerID == offerID })

            await #expect(throws: (any Error).self) { try await service.declineIncomingTransfer(offerID, accountID: accountID) }
            await #expect(throws: (any Error).self) { try await service.acceptIncomingTransfer(offerID, accountID: accountID) }

            server.release()
            try await accept.value
            guard case .received? = service.activeTransfers.first(where: { $0.sid == "oob-busy" })?.state else {
                Issue.record("Expected the one download to be received")
                await Self.tearDown(harness)
                return
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
            await Self.tearDown(harness)
        }

        /// A session-accept that fails to go out leaves the session acceptable, so the offer returns to the banner.
        @Test
        func `A session-accept that fails to send returns the offer for another try`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "retry-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "retry-sid")

            await harness.transport.simulateSendFailure(XMPPClientError.notConnected)
            await #expect(throws: (any Error).self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }
            await harness.transport.simulateSendFailure(nil)

            #expect(harness.service.incomingOffers.contains { $0.offer.sid == "retry-sid" })
            #expect(!harness.service.activeTransfers.contains { $0.sid == "retry-sid" })

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            _ = Self.takeTransferTask(harness.service)
            #expect(harness.service.activeTransfers.contains { $0.sid == "retry-sid" })
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
            let initiate = try #require(await harness.transport.waitForSent { $0.contains("session-initiate") })
            #expect(initiate.contains("algo=\"sha-256\""))
            #expect(initiate.contains(JingleFileDescription.sha256Hash(of: Array("abc".utf8))))
            // The offer's session exists once the peer acknowledged it.
            let initiateID = try #require(initiate.firstMatch(of: /\sid=["']([^"']+)["']/)?.output.1)
            await harness.transport.simulateReceive("<iq type='result' id='\(initiateID)' from='\(Self.peerJID)'/>")
            try await Self.poll { harness.service.activeTransfers.contains { $0.method == .jingle } }
            let sid = try #require(harness.service.activeTransfers.first { $0.method == .jingle }?.sid)

            await Self.deliverDecline(harness, sid: sid)
            let outcome = try await boundedOutcome { _ = try? await sendTask.value }
            #expect(outcome != nil)

            #expect(failureReason(harness.service, sid: sid) == "The peer declined the transfer")
            await Self.tearDown(harness)
        }

        @Test
        func `Accepting an offer replaces its banner with a connecting transfer`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "banner-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "banner-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)

            #expect(harness.service.incomingOffers.isEmpty)
            let state = harness.service.activeTransfers.first { $0.sid == "banner-sid" }?.state
            guard case .connectingTransport? = state else {
                Issue.record("Expected connectingTransport, got \(String(describing: state))")
                await Self.tearDown(harness)
                return
            }
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer's row follows progress and then completion`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "state-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "state-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let tasks = Self.takeTransferTask(harness.service)

            harness.service.handleJingleEvent(
                .jingleFileTransferProgress(sid: "state-sid", bytesTransferred: 500, totalBytes: 1000),
                accountID: harness.accountID
            )
            if case let .transferring(progress)? = harness.service.activeTransfers.first(where: { $0.sid == "state-sid" })?.state {
                #expect(progress == 0.5)
            } else {
                Issue.record("Expected transferring, got \(String(describing: harness.service.activeTransfers.first { $0.sid == "state-sid" }?.state))")
            }

            harness.service.handleJingleEvent(
                .jingleFileTransferCompleted(sid: "state-sid", transport: .ibb), accountID: harness.accountID
            )
            if case .completedTransfer? = harness.service.activeTransfers.first(where: { $0.sid == "state-sid" })?.state {
                // Expected
            } else {
                Issue.record("Expected completedTransfer, got \(String(describing: harness.service.activeTransfers.first { $0.sid == "state-sid" }?.state))")
            }

            await Self.deliverDecline(harness, sid: "state-sid")
            try await Self.drain(tasks)
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer claims its receive`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "claim-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "claim-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let client = try #require(harness.accountService.connectedClient(for: harness.accountID))
            let module = try #require(await client.module(ofType: JingleModule.self))

            // A transport-replace is accepted until the receive task claims the transfer, and rejected from then on.
            var isClaimed = false
            for attempt in 0 ..< 50 where !isClaimed {
                await harness.transport.clearSentBytes()
                await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "claim-sid", ibbSID: "ibb-probe-\(attempt)"))
                let reply = await harness.transport.waitForSent { $0.contains("transport-accept") || $0.contains("transport-reject") }
                isClaimed = reply?.contains("transport-reject") == true
            }
            #expect(isClaimed)

            await #expect(throws: JingleModule.JingleError.transportFailed("The transfer is already being received")) {
                _ = try await module.receiveFileData(sid: "claim-sid")
            }
            await Self.tearDown(harness)
        }

        @Test
        func `An accepted transfer saves the file and adds it to the sender's conversation`() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jingle-downloads-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "save-sid"))
            let offerID = try await Self.waitForOffer(harness, wireID: "save-sid")

            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            await harness.transport.simulateReceive(Self.transportReplaceXML(sid: "save-sid", ibbSID: "ibb-save"))
            await harness.transport.simulateReceive(
                "<iq type='set' id='data-0' from='\(Self.peerJID)'><data xmlns='http://jabber.org/protocol/ibb' sid='ibb-save' seq='0'>AQID</data></iq>"
            )
            await harness.transport.simulateReceive(
                "<iq type='set' id='close-0' from='\(Self.peerJID)'><close xmlns='http://jabber.org/protocol/ibb' sid='ibb-save'/></iq>"
            )
            try await Self.poll { Self.savedFileURL(harness.service, sid: "save-sid") != nil }

            let fileURL = try #require(Self.savedFileURL(harness.service, sid: "save-sid"))
            #expect(fileURL.lastPathComponent == "test.txt")
            #expect(try Data(contentsOf: fileURL) == Data([1, 2, 3]))
            let conversation = try #require(try await harness.store.fetchConversations(for: harness.accountID).first)
            #expect(conversation.jid.description == "bob@example.com")
            let message = try #require(await harness.chatService.loadMessages(for: conversation.id).first)
            #expect(!message.isOutgoing)
            #expect(message.attachments.first?.url == fileURL.absoluteString)
            // Recorded as this app's own file, which is what gives it Quick Look and Reveal in Finder.
            #expect(message.attachments.first?.origin == .locallySaved)
            #expect(message.attachments.first?.localFileURL == fileURL)

            // The transport's own completion is dispatched independently of the save, which awaits both a disk write
            // and a transcript append, so it can land after it. Replayed here in that order: the row has to keep the
            // file it saved, or the UI is left with a bare completion and nothing for Quick Look and Reveal to open.
            harness.service.handleJingleEvent(
                .jingleFileTransferCompleted(sid: "save-sid", transport: .ibb), accountID: harness.accountID
            )
            harness.service.handleJingleEvent(
                .jingleFileTransferProgress(sid: "save-sid", bytesTransferred: 1, totalBytes: 3), accountID: harness.accountID
            )
            #expect(Self.savedFileURL(harness.service, sid: "save-sid") == fileURL)
            await Self.tearDown(harness)
        }

        private static func oobOfferXML(id: String, url: URL, from sender: String) -> String {
            "<iq type='set' id='\(id)' from='\(sender)'><query xmlns='jabber:iq:oob'><url>\(url.absoluteString)</url></query></iq>"
        }

        private static func sentStanzas(_ harness: Harness) async -> [String] {
            await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        }

        /// A Jingle sid and a link's stanza id are both the peer's to pick, so they can be equal. Accepting the Jingle offer
        /// takes that offer, and the link stays waiting with nothing fetched.
        @Test
        func `Accepting a Jingle offer leaves a link offer under the same id untouched`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [1])]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "same-id", url: server.url()))
            let linkOfferID = try await Self.waitForOffer(harness, wireID: "same-id")
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "same-id"))
            try await Self.poll { !harness.service.incomingOffers.isEmpty }
            let fileOfferID = try #require(harness.service.incomingOffers.first?.offer.offerID)

            try await harness.service.acceptIncomingTransfer(fileOfferID, accountID: harness.accountID)
            _ = Self.takeTransferTask(harness.service)

            #expect(server.requests.isEmpty)
            #expect(harness.service.viewIncomingOffers.map(\.offerID) == [linkOfferID])
            guard case .connectingTransport? = harness.service.activeTransfers.first(where: { $0.method == .jingle })?.state else {
                Issue.record("Expected the Jingle offer's transfer to start")
                await Self.tearDown(harness)
                return
            }
            await Self.tearDown(harness)
        }

        /// Two senders' links under one stanza id are two offers: taking one leaves the other waiting, and the answer goes
        /// to the sender whose link was taken.
        @Test
        func `Accepting one of two links under the same stanza id leaves the other waiting`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [9])]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            let other = "carol@example.com/res"
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "shared-id", url: server.url()))
            let first = try await Self.waitForOffer(harness, wireID: "shared-id", from: Self.peerJID)
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "shared-id", url: server.url(), from: other))
            let second = try await Self.waitForOffer(harness, wireID: "shared-id", from: other)
            await harness.transport.clearSentBytes()

            try await harness.service.acceptIncomingTransfer(first, accountID: harness.accountID)

            #expect(harness.service.viewIncomingOffers.map(\.offerID) == [second])
            let waitingRows = harness.service.activeTransfers.filter { row in
                if case .awaitingAcceptance = row.state { return true }
                return false
            }
            #expect(waitingRows.count == 1)
            let answers = await Self.sentStanzas(harness).filter { $0.contains("type=\"result\"") }
            #expect(answers.count == 1)
            #expect(answers.first?.contains("to=\"\(Self.peerJID)\"") == true)
            await Self.tearDown(harness)
        }

        /// Decline acts on an offer. Once the offer was accepted the transfer is under way, and declining the id it had
        /// must not end that transfer.
        @Test
        func `Declining an accepted offer does not end its transfer`() async throws {
            let harness = try await Self.connect()
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "taken-sid"))
            let taken = try await Self.waitForOffer(harness, wireID: "taken-sid")
            await harness.transport.simulateReceive(Self.sessionInitiateXML(sid: "waiting-sid"))
            let waiting = try await Self.waitForOffer(harness, wireID: "waiting-sid")
            try await harness.service.acceptIncomingTransfer(taken, accountID: harness.accountID)
            _ = Self.takeTransferTask(harness.service)

            // Control: declining an offer still waiting does end its session.
            await harness.transport.clearSentBytes()
            try await harness.service.declineIncomingTransfer(waiting, accountID: harness.accountID)
            #expect(await Self.sentStanzas(harness).contains { $0.contains("session-terminate") && $0.contains("waiting-sid") })

            await harness.transport.clearSentBytes()
            let error = await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.declineIncomingTransfer(taken, accountID: harness.accountID)
            }
            #expect(isOfferNotFound(error))
            #expect(await !Self.sentStanzas(harness).contains { $0.contains("session-terminate") })
            guard case .connectingTransport? = harness.service.activeTransfers.first(where: { $0.sid == "taken-sid" })?.state else {
                Issue.record("Expected the accepted transfer to keep connecting")
                await Self.tearDown(harness)
                return
            }
            await Self.tearDown(harness)
        }

        @Test
        func `Declining a link offer answers it and marks its row declined`() async throws {
            let harness = try await Self.connect()
            try await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-decline", url: #require(URL(string: "https://example.com/a.bin"))))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-decline")
            await harness.transport.clearSentBytes()

            try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)

            #expect(harness.service.viewIncomingOffers.isEmpty)
            #expect(failureReason(harness.service, sid: "oob-decline") == "You declined the transfer")
            #expect(await Self.sentStanzas(harness).contains { $0.contains("oob-decline") && $0.contains("not-acceptable") })
            await Self.tearDown(harness)
        }

        /// A rejection that did not go out leaves the offer waiting, and declining again answers it.
        @Test
        func `A link rejection that fails to send keeps the offer for another try`() async throws {
            let harness = try await Self.connect()
            try await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-reject", url: #require(URL(string: "https://example.com/a.bin"))))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-reject")

            await harness.transport.simulateSendFailure(XMPPClientError.notConnected)
            await #expect(throws: (any Error).self) {
                try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)
            }
            await harness.transport.simulateSendFailure(nil)
            #expect(harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
            guard case .awaitingAcceptance? = harness.service.activeTransfers.first(where: { $0.sid == "oob-reject" })?.state else {
                Issue.record("Expected the row to keep waiting")
                await Self.tearDown(harness)
                return
            }

            await harness.transport.clearSentBytes()
            try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)
            #expect(await Self.sentStanzas(harness).contains { $0.contains("oob-reject") && $0.contains("not-acceptable") })
            await Self.tearDown(harness)
        }

        /// Without a connection there is nobody to answer, so an accept fails before it takes the offer off the banner.
        @Test
        func `Accepting or declining a link while disconnected keeps the offer`() async throws {
            let harness = try await Self.connect()
            try await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-offline", url: #require(URL(string: "https://example.com/a.bin"))))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-offline")
            harness.connectTask.cancel()
            await harness.accountService.disconnectAll()

            await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            }
            await #expect(throws: FileTransferService.FileTransferError.self) {
                try await harness.service.declineIncomingTransfer(offerID, accountID: harness.accountID)
            }
            #expect(harness.service.viewIncomingOffers.contains { $0.offerID == offerID })
        }

        /// The file is saved and recorded before the answer goes out, so an answer that cannot be sent does not undo the
        /// transfer or report it as failed.
        @Test
        func `A link whose acknowledgement fails to send is still received`() async throws {
            let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: [5, 6])]))
            defer { server.stop() }
            let directory = Self.downloadsFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let harness = try await Self.connect(downloadsDirectory: directory)
            await harness.transport.simulateReceive(Self.oobOfferXML(id: "oob-ack", url: server.url()))
            let offerID = try await Self.waitForOffer(harness, wireID: "oob-ack")

            await harness.transport.clearSentBytes()
            await harness.transport.simulateSendFailure(XMPPClientError.notConnected)
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            await harness.transport.simulateSendFailure(nil)

            guard case let .received(fileURL)? = harness.service.activeTransfers.first(where: { $0.sid == "oob-ack" })?.state else {
                Issue.record("Expected the downloaded link to be received")
                await Self.tearDown(harness)
                return
            }
            #expect(try Data(contentsOf: fileURL) == Data([5, 6]))
            #expect(await !Self.answeredOffer(harness, id: "oob-ack"))
            await Self.tearDown(harness)
        }

        private static func savedFileURL(_ service: FileTransferService, sid: String) -> URL? {
            guard case let .received(fileURL) = service.activeTransfers.first(where: { $0.sid == sid })?.state else { return nil }
            return fileURL
        }
    }
}
