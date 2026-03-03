import Foundation
import Testing
@testable import DuckoCore

enum FileTransferServiceTests {
    private static func makeConversation() -> Conversation {
        Conversation(
            id: UUID(),
            accountID: UUID(),
            jid: .parse("friend@example.com")!,
            type: .chat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    @MainActor
    struct Initialization {
        @Test("Starts with empty active transfers")
        func startsEmpty() {
            let store = MockPersistenceStore()
            let service = FileTransferService(store: store)
            #expect(service.activeTransfers.isEmpty)
        }
    }

    @MainActor
    struct SendFileErrors {
        @Test("Throws fileReadFailed for missing file")
        func throwsFileReadFailed() async throws {
            let store = MockPersistenceStore()
            let service = FileTransferService(store: store)

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
        @Test("Throws noClient when no account service is set")
        func throwsNoClient() async throws {
            let store = MockPersistenceStore()
            let service = FileTransferService(store: store)

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
        @Test("Transfer appears in activeTransfers during send attempt")
        func tracksTransfer() async throws {
            let store = MockPersistenceStore()
            let service = FileTransferService(store: store)

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
}
