import DuckoXMPP
import Foundation
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.ducko.core", category: "fileTransfer")

@MainActor @Observable
public final class FileTransferService {
    // MARK: - Types

    public struct ActiveTransfer: Sendable, Identifiable {
        public let id: UUID
        public let fileName: String
        public let fileSize: Int64
        public let mimeType: String
        public var state: TransferState

        public init(id: UUID, fileName: String, fileSize: Int64, mimeType: String, state: TransferState) {
            self.id = id
            self.fileName = fileName
            self.fileSize = fileSize
            self.mimeType = mimeType
            self.state = state
        }
    }

    public enum TransferState: Sendable {
        case requestingSlot
        case uploading(progress: Double)
        case completed(downloadURL: String)
        case failed(String)
    }

    public enum FileTransferError: Error, LocalizedError {
        case fileReadFailed(String)
        case noClient
        case noUploadModule
        case uploadFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .fileReadFailed(reason): "File read failed: \(reason)"
            case .noClient: "No XMPP client available"
            case .noUploadModule: "HTTP upload module not available"
            case let .uploadFailed(reason): "Upload failed: \(reason)"
            }
        }
    }

    // MARK: - State

    public private(set) var activeTransfers: [ActiveTransfer] = []

    private let store: any PersistenceStore
    private weak var accountService: AccountService?
    private weak var chatService: ChatService?

    public init(store: any PersistenceStore) {
        self.store = store
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setChatService(_ service: ChatService) {
        chatService = service
    }

    // MARK: - Public API

    public func sendFile(url: URL, in conversation: Conversation, accountID: UUID) async throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FileTransferError.fileReadFailed(error.localizedDescription)
        }
        let fileSize = (attributes[.size] as? Int64) ?? 0
        let fileName = url.lastPathComponent
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        let transferID = UUID()
        let transfer = ActiveTransfer(
            id: transferID,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            state: .requestingSlot
        )
        activeTransfers.append(transfer)

        do {
            let slot = try await requestUploadSlot(fileName: fileName, fileSize: fileSize, mimeType: mimeType, accountID: accountID)
            let downloadURL = try await performUpload(fileURL: url, slot: slot, mimeType: mimeType, transferID: transferID)
            try await sendDownloadURL(downloadURL, in: conversation, accountID: accountID)
            updateTransferState(id: transferID, state: .completed(downloadURL: downloadURL))
        } catch {
            updateTransferState(id: transferID, state: .failed(error.localizedDescription))
            throw error
        }
    }

    public func sendImage(data: Data, mimeType: String = "image/jpeg", in conversation: Conversation, accountID: UUID) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "jpg"
        let fileName = "image-\(UUID().uuidString).\(ext)"
        let tempURL = tempDir.appendingPathComponent(fileName)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try await sendFile(url: tempURL, in: conversation, accountID: accountID)
    }

    // MARK: - Private

    private func requestUploadSlot(
        fileName: String,
        fileSize: Int64,
        mimeType: String,
        accountID: UUID
    ) async throws -> HTTPUploadModule.UploadSlot {
        guard let client = accountService?.client(for: accountID) else {
            throw FileTransferError.noClient
        }
        guard let uploadModule = await client.module(ofType: HTTPUploadModule.self) else {
            throw FileTransferError.noUploadModule
        }
        return try await uploadModule.requestSlot(filename: fileName, size: fileSize, contentType: mimeType)
    }

    private func performUpload(
        fileURL: URL,
        slot: HTTPUploadModule.UploadSlot,
        mimeType: String,
        transferID: UUID
    ) async throws -> String {
        updateTransferState(id: transferID, state: .uploading(progress: 0))

        guard let putURL = URL(string: slot.putURL) else {
            throw FileTransferError.uploadFailed("Invalid PUT URL")
        }

        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        for (name, value) in slot.putHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw FileTransferError.uploadFailed("HTTP \(statusCode)")
        }

        updateTransferState(id: transferID, state: .uploading(progress: 1.0))
        return slot.getURL
    }

    private func sendDownloadURL(_ downloadURL: String, in conversation: Conversation, accountID: UUID) async throws {
        guard let chatService else {
            throw FileTransferError.uploadFailed("Chat service not available")
        }
        let jid = conversation.jid
        switch conversation.type {
        case .chat:
            try await chatService.sendMessage(to: jid, body: downloadURL, accountID: accountID)
        case .groupchat:
            try await chatService.sendGroupMessage(to: jid, body: downloadURL, accountID: accountID)
        }
    }

    private func updateTransferState(id: UUID, state: TransferState) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            activeTransfers[index].state = state
        }
    }
}
