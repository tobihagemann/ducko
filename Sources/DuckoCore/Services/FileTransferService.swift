import Foundation

@MainActor @Observable
public final class FileTransferService {
    public struct ActiveTransfer: Sendable, Identifiable {
        public let id: UUID
        public let fileName: String
        public var progress: Double

        public init(id: UUID, fileName: String, progress: Double) {
            self.id = id
            self.fileName = fileName
            self.progress = progress
        }
    }

    public private(set) var activeTransfers: [ActiveTransfer] = []

    public init() {}

    public func sendFile(url: URL, in conversation: Conversation) async throws {
        // Stub — will be implemented with HTTPUploadModule in a future prompt.
    }

    public func sendImage(data: Data, in conversation: Conversation) async throws {
        // Stub — will be implemented with HTTPUploadModule in a future prompt.
    }
}
