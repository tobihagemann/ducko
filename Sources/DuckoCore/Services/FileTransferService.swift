import DuckoXMPP
import Foundation
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.ducko.core", category: "fileTransfer")

@MainActor @Observable
public final class FileTransferService {
    // MARK: - Types

    public enum TransferMethod: Sendable {
        case auto
        case httpUpload
        case jingle
    }

    public enum TransferDirection: Sendable {
        case outgoing
        case incoming
    }

    /// View-friendly representation of an incoming Jingle file offer.
    /// Uses strings instead of DuckoXMPP types so DuckoUI can access it without importing DuckoXMPP.
    public struct IncomingFileOffer: Sendable, Identifiable {
        public var id: String {
            sid
        }

        public let sid: String
        public let fileName: String
        public let fileSize: Int64
        public let fromJIDString: String

        public init(sid: String, fileName: String, fileSize: Int64, fromJIDString: String) {
            self.sid = sid
            self.fileName = fileName
            self.fileSize = fileSize
            self.fromJIDString = fromJIDString
        }
    }

    public struct ActiveTransfer: Sendable, Identifiable {
        public let id: UUID
        public let fileName: String
        public let fileSize: Int64
        public var state: TransferState
        public let method: TransferMethod
        public let direction: TransferDirection
        public let sid: String?

        public init(
            id: UUID, fileName: String, fileSize: Int64,
            state: TransferState, method: TransferMethod = .httpUpload,
            direction: TransferDirection = .outgoing, sid: String? = nil
        ) {
            self.id = id
            self.fileName = fileName
            self.fileSize = fileSize
            self.state = state
            self.method = method
            self.direction = direction
            self.sid = sid
        }
    }

    public enum TransferState: Sendable {
        // HTTP Upload
        case requestingSlot
        case uploading(progress: Double)
        case completed(downloadURL: String)
        case failed(String)
        // Jingle
        case negotiating
        case connectingTransport
        case transferring(progress: Double)
        case awaitingAcceptance
        case completedTransfer
    }

    public enum FileTransferError: Error, LocalizedError {
        case fileReadFailed(String)
        case noClient
        case noUploadModule
        case noJingleModule
        case uploadFailed(String)
        case jingleFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .fileReadFailed(reason): "File read failed: \(reason)"
            case .noClient: "No XMPP client available"
            case .noUploadModule: "HTTP upload module not available"
            case .noJingleModule: "Jingle module not available"
            case let .uploadFailed(reason): "Upload failed: \(reason)"
            case let .jingleFailed(reason): "Jingle transfer failed: \(reason)"
            }
        }
    }

    /// Bundles file metadata extracted from the file system.
    private struct FileInfo {
        let url: URL
        let name: String
        let size: Int64
        let mimeType: String
    }

    // MARK: - State

    public private(set) var activeTransfers: [ActiveTransfer] = []
    public private(set) var incomingOffers: [JingleFileOffer] = []

    /// View-friendly projection of `incomingOffers` for modules that cannot import DuckoXMPP.
    public var viewIncomingOffers: [IncomingFileOffer] {
        incomingOffers.map {
            IncomingFileOffer(sid: $0.sid, fileName: $0.fileName, fileSize: $0.fileSize, fromJIDString: $0.from.bareJID.description)
        }
    }

    private weak var accountService: AccountService?
    private weak var chatService: ChatService?

    public init() {}

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setChatService(_ service: ChatService) {
        chatService = service
    }

    // MARK: - Public API

    @discardableResult
    public func sendFile(
        url: URL, in conversation: Conversation, accountID: UUID,
        method: TransferMethod = .auto,
        peerJID: String? = nil,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FileTransferError.fileReadFailed(error.localizedDescription)
        }
        let file = FileInfo(
            url: url,
            name: url.lastPathComponent,
            size: (attributes[.size] as? Int64) ?? 0,
            mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        )

        let resolved = await resolveMethod(method, peerJIDString: peerJID ?? conversation.jid.description, accountID: accountID)

        switch resolved {
        case .httpUpload, .auto:
            return try await sendFileViaHTTP(file, in: conversation, accountID: accountID, onProgress: onProgress)
        case .jingle:
            let peer = peerJID ?? conversation.jid.description
            return try await sendFileViaJingle(file, peer: peer, accountID: accountID, onProgress: onProgress)
        }
    }

    // MARK: - Jingle Event Handling

    public func handleJingleEvent(_ event: XMPPEvent, accountID _: UUID) {
        switch event {
        case let .jingleFileTransferReceived(offer):
            incomingOffers.append(offer)
            let transfer = ActiveTransfer(
                id: UUID(),
                fileName: offer.fileName,
                fileSize: offer.fileSize,
                state: .awaitingAcceptance,
                method: .jingle,
                direction: .incoming,
                sid: offer.sid
            )
            activeTransfers.append(transfer)
        case let .jingleFileTransferProgress(sid, bytesTransferred, totalBytes):
            let progress = Double(bytesTransferred) / Double(totalBytes)
            updateTransferState(forSID: sid, state: .transferring(progress: progress))
        case let .jingleFileTransferCompleted(sid):
            updateTransferState(forSID: sid, state: .completedTransfer)
            incomingOffers.removeAll { $0.sid == sid }
        case let .jingleFileTransferFailed(sid, reason):
            updateTransferState(forSID: sid, state: .failed(reason))
            incomingOffers.removeAll { $0.sid == sid }
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived,
             .roomDestroyed,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            break
        }
    }

    // MARK: - Incoming Transfer Management

    public func acceptIncomingTransfer(_ sid: String, accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)

        try await jingleModule.acceptFileTransfer(sid: sid)

        let offer = incomingOffers.first { $0.sid == sid }
        guard let offer else { return }

        Task {
            do {
                try await jingleModule.awaitTransportReady(sid: sid)
                let data = try await jingleModule.receiveFileData(sid: sid, expectedSize: offer.fileSize)
                log.info("Received \(data.count) bytes via Jingle for sid: \(sid)")
            } catch {
                log.warning("Jingle receive failed for sid \(sid): \(error)")
                updateTransferState(forSID: sid, state: .failed(error.localizedDescription))
            }
        }
    }

    public func declineIncomingTransfer(_ sid: String, accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)

        try await jingleModule.declineFileTransfer(sid: sid)
        incomingOffers.removeAll { $0.sid == sid }
    }

    // MARK: - Private: Method Resolution

    private func resolveMethod(_ method: TransferMethod, peerJIDString: String, accountID: UUID) async -> TransferMethod {
        switch method {
        case .httpUpload, .jingle:
            return method
        case .auto:
            if FullJID.parse(peerJIDString) != nil,
               let peerJID = BareJID.parse(peerJIDString),
               await peerSupportsJingle(peerJID, accountID: accountID) {
                return .jingle
            }
            return .httpUpload
        }
    }

    private func peerSupportsJingle(_ peerJID: BareJID, accountID: UUID) async -> Bool {
        guard let client = accountService?.client(for: accountID) else { return false }
        guard let capsModule = await client.module(ofType: CapsModule.self) else { return false }
        return capsModule.isFeatureSupported(XMPPNamespaces.jingle, by: peerJID)
    }

    // MARK: - Private: HTTP Upload

    private func sendFileViaHTTP(
        _ file: FileInfo, in conversation: Conversation, accountID: UUID,
        onProgress: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> String {
        let transferID = UUID()
        let transfer = ActiveTransfer(
            id: transferID,
            fileName: file.name,
            fileSize: file.size,
            state: .requestingSlot,
            method: .httpUpload,
            direction: .outgoing
        )
        activeTransfers.append(transfer)

        do {
            let slot = try await requestUploadSlot(fileName: file.name, fileSize: file.size, mimeType: file.mimeType, accountID: accountID)
            let downloadURL = try await performUpload(fileURL: file.url, slot: slot, mimeType: file.mimeType, transferID: transferID, onProgress: onProgress)
            // Yield to drain any pending progress callbacks before setting terminal state
            await Task.yield()
            try await sendDownloadURL(downloadURL, in: conversation, accountID: accountID)
            updateTransferState(id: transferID, state: .completed(downloadURL: downloadURL))
            return downloadURL
        } catch {
            await Task.yield()
            updateTransferState(id: transferID, state: .failed(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Private: Jingle Transfer

    private func sendFileViaJingle(
        _ file: FileInfo, peer: String, accountID: UUID,
        onProgress _: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> String {
        let jingleModule = try await jingleModule(for: accountID)

        guard let peerJID = FullJID.parse(peer) else {
            // Jingle requires a full JID (with resource) to target a specific client.
            // BareJID conversations need resource resolution via presence before Jingle.
            throw FileTransferError.jingleFailed("Jingle requires a full JID with resource, got: \(peer)")
        }

        let fileDesc = JingleFileDescription(name: file.name, size: file.size, mediaType: file.mimeType)
        let sid = try await jingleModule.initiateFileTransfer(to: peerJID, file: fileDesc)

        let transferID = UUID()
        let transfer = ActiveTransfer(
            id: transferID,
            fileName: file.name,
            fileSize: file.size,
            state: .negotiating,
            method: .jingle,
            direction: .outgoing,
            sid: sid
        )
        activeTransfers.append(transfer)

        do {
            try await jingleModule.awaitTransportReady(sid: sid)
            updateTransferState(id: transferID, state: .connectingTransport)

            let fileData = try Array(Data(contentsOf: file.url))
            updateTransferState(id: transferID, state: .transferring(progress: 0))

            try await jingleModule.sendFileData(sid: sid, data: fileData)
            updateTransferState(id: transferID, state: .completedTransfer)
            return ""
        } catch {
            updateTransferState(id: transferID, state: .failed(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Private: HTTP Upload Helpers

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
        transferID: UUID,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
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

        let delegate = UploadProgressDelegate { progress in
            Task { @MainActor in
                self.updateTransferState(id: transferID, state: .uploading(progress: progress))
                onProgress?(progress)
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
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

    // MARK: - Private: Module Lookup

    private func jingleModule(for accountID: UUID) async throws -> JingleModule {
        guard let client = accountService?.client(for: accountID) else {
            throw FileTransferError.noClient
        }
        guard let module = await client.module(ofType: JingleModule.self) else {
            throw FileTransferError.noJingleModule
        }
        return module
    }

    // MARK: - Private: State Updates

    private func updateTransferState(id: UUID, state: TransferState) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            activeTransfers[index].state = state
        }
    }

    private func updateTransferState(forSID sid: String, state: TransferState) {
        if let index = activeTransfers.firstIndex(where: { $0.sid == sid }) {
            activeTransfers[index].state = state
        }
    }
}

// MARK: - Upload Progress Delegate

/// URLSession delegate that reports upload progress. Must be a class conforming to NSObject
/// for URLSession delegate requirements — `@unchecked Sendable` is required because
/// URLSessionTaskDelegate is not Sendable but the callback is safe to call from any thread.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(progress)
    }
}
