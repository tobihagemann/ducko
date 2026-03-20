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

            let transfer = service.activeTransfers.first { $0.sid == "session-1/file-0" }
            if case .failed = transfer?.state {
                // Expected
            } else {
                Issue.record("Expected failed state after content rejection")
            }
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
}
