import DuckoXMPP
import Foundation
import Logging
import UniformTypeIdentifiers

private let log = Logger(label: "im.ducko.core.fileTransfer")

private struct FileAttributes {
    let fileName: String
    let fileSize: Int64
    let mimeType: String
}

/// Reads file name, size, and MIME type from a local file URL.
private func readFileAttributes(at url: URL) throws -> FileAttributes {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return FileAttributes(
        fileName: url.lastPathComponent,
        fileSize: (attributes[.size] as? Int64) ?? 0,
        mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    )
}

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

    /// View-friendly representation of an incoming Jingle content-add offer.
    public struct IncomingContentAddOffer: Sendable, Identifiable {
        public var id: String {
            "\(sid)/\(contentName)"
        }

        public let sid: String
        public let contentName: String
        public let fileName: String
        public let fileSize: Int64
        public let fromJIDString: String
    }

    /// Tracking type for a Jingle content-add offer.
    public struct PendingContentAdd: Sendable {
        public let sid: String
        public let contentName: String
        public let offer: JingleFileOffer
    }

    /// View-friendly representation of an incoming Jingle file request.
    public struct IncomingFileRequest: Sendable, Identifiable {
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

        /// Whether this is a session-level Jingle transfer (not a content-add sub-transfer).
        /// Content-add sub-transfers use a composite sid of `sessionSID/contentName`.
        public var isSessionLevel: Bool {
            guard let sid else { return false }
            return method == .jingle && direction == .outgoing && !sid.contains("/")
        }

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
        case checksumMismatch(sid: String)
        case checksumUnsupportedAlgorithm(sid: String, algo: String)

        public var errorDescription: String? {
            switch self {
            case let .fileReadFailed(reason): "File read failed: \(reason)"
            case .noClient: "No XMPP client available"
            case .noUploadModule: "HTTP upload module not available"
            case .noJingleModule: "Jingle module not available"
            case let .uploadFailed(reason): "Upload failed: \(reason)"
            case let .jingleFailed(reason): "Jingle transfer failed: \(reason)"
            case let .checksumMismatch(sid): "Checksum mismatch for file transfer \(sid) — file data is corrupted"
            case let .checksumUnsupportedAlgorithm(sid, algo):
                "Cannot verify file integrity for \(sid): unsupported hash algorithm '\(algo)'"
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
    public private(set) var incomingContentAddOffers: [PendingContentAdd] = []
    public private(set) var incomingRequests: [JingleFileRequest] = []
    private var pendingOOBOfferIDs: Set<String> = []

    /// View-friendly projection of `incomingOffers` for modules that cannot import DuckoXMPP.
    public var viewIncomingOffers: [IncomingFileOffer] {
        incomingOffers.map {
            IncomingFileOffer(sid: $0.sid, fileName: $0.fileName, fileSize: $0.fileSize, fromJIDString: $0.from.bareJID.description)
        }
    }

    /// View-friendly projection of `incomingContentAddOffers` for modules that cannot import DuckoXMPP.
    public var viewIncomingContentAddOffers: [IncomingContentAddOffer] {
        incomingContentAddOffers.map {
            IncomingContentAddOffer(
                sid: $0.sid, contentName: $0.contentName,
                fileName: $0.offer.fileName, fileSize: $0.offer.fileSize,
                fromJIDString: $0.offer.from.bareJID.description
            )
        }
    }

    /// View-friendly projection of `incomingRequests` for modules that cannot import DuckoXMPP.
    public var viewIncomingRequests: [IncomingFileRequest] {
        incomingRequests.map {
            IncomingFileRequest(
                sid: $0.sid, fileName: $0.fileDescription.name,
                fileSize: $0.fileDescription.size, fromJIDString: $0.from.bareJID.description
            )
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
        let attrs: FileAttributes
        do {
            attrs = try readFileAttributes(at: url)
        } catch {
            throw FileTransferError.fileReadFailed(error.localizedDescription)
        }
        let file = FileInfo(
            url: url,
            name: attrs.fileName,
            size: attrs.fileSize,
            mimeType: attrs.mimeType
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
            trackIncomingOffer(offer)
        case let .jingleFileRequestReceived(request):
            handleIncomingFileRequest(request)
        case let .jingleFileTransferProgress(sid, bytesTransferred, totalBytes):
            let progress = Double(bytesTransferred) / Double(totalBytes)
            updateTransferState(forSID: sid, state: .transferring(progress: progress))
        case let .jingleFileTransferCompleted(sid):
            updateTransferState(forSID: sid, state: .completedTransfer)
            updateContentAddTransferStates(forSessionSID: sid, state: .completedTransfer)
            incomingOffers.removeAll { $0.sid == sid }
            incomingRequests.removeAll { $0.sid == sid }
            incomingContentAddOffers.removeAll { $0.sid == sid }
        case let .jingleFileTransferFailed(sid, reason):
            updateTransferState(forSID: sid, state: .failed(reason))
            updateContentAddTransferStates(forSessionSID: sid, state: .failed(reason))
            incomingOffers.removeAll { $0.sid == sid }
            incomingRequests.removeAll { $0.sid == sid }
            incomingContentAddOffers.removeAll { $0.sid == sid }
        case .jingleContentAddReceived, .jingleContentAccepted, .jingleContentRejected, .jingleContentRemoved:
            handleContentAddEvent(event)
        case let .oobIQOfferReceived(offer):
            trackIncomingOOBOffer(offer)
        case .jingleChecksumReceived, .jingleChecksumMismatch:
            break
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterLoaded, .rosterItemChanged, .rosterVersionChanged,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced,
             .serviceOutageReceived:
            break
        }
    }

    private func trackIncomingOOBOffer(_ offer: OOBIQOffer) {
        pendingOOBOfferIDs.insert(offer.id)
        let fileName = URL(string: offer.url)?.lastPathComponent ?? offer.url
        let transfer = ActiveTransfer(
            id: UUID(),
            fileName: fileName,
            fileSize: 0,
            state: .awaitingAcceptance,
            method: .httpUpload,
            direction: .incoming,
            sid: offer.id
        )
        activeTransfers.append(transfer)
    }

    private func trackIncomingOffer(_ offer: JingleFileOffer) {
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
    }

    private func handleContentAddEvent(_ event: XMPPEvent) {
        switch event {
        case let .jingleContentAddReceived(sid, contentName, offer):
            trackIncomingContentAdd(sid: sid, contentName: contentName, offer: offer)
        case let .jingleContentAccepted(sid, contentName):
            log.info("Content accepted: \(Self.contentAddID(sid: sid, contentName: contentName))")
        case let .jingleContentRejected(sid, contentName):
            let id = Self.contentAddID(sid: sid, contentName: contentName)
            incomingContentAddOffers.removeAll { Self.contentAddID(sid: $0.sid, contentName: $0.contentName) == id }
            updateTransferState(forSID: id, state: .failed("Content rejected by peer"))
        case let .jingleContentRemoved(sid, contentName):
            let id = Self.contentAddID(sid: sid, contentName: contentName)
            incomingContentAddOffers.removeAll { Self.contentAddID(sid: $0.sid, contentName: $0.contentName) == id }
            updateTransferState(forSID: id, state: .failed("Content removed by peer"))
        default:
            break
        }
    }

    private static func contentAddID(sid: String, contentName: String) -> String {
        "\(sid)/\(contentName)"
    }

    private func trackIncomingContentAdd(sid: String, contentName: String, offer: JingleFileOffer) {
        incomingContentAddOffers.append(PendingContentAdd(sid: sid, contentName: contentName, offer: offer))
        let id = Self.contentAddID(sid: sid, contentName: contentName)
        let transfer = ActiveTransfer(
            id: UUID(),
            fileName: offer.fileName,
            fileSize: offer.fileSize,
            state: .awaitingAcceptance,
            method: .jingle,
            direction: .incoming,
            sid: id
        )
        activeTransfers.append(transfer)
    }

    private func handleIncomingFileRequest(_ request: JingleFileRequest) {
        incomingRequests.append(request)
        let transfer = ActiveTransfer(
            id: UUID(),
            fileName: request.fileDescription.name,
            fileSize: request.fileDescription.size,
            state: .awaitingAcceptance,
            method: .jingle,
            direction: .outgoing,
            sid: request.sid
        )
        activeTransfers.append(transfer)
    }

    // MARK: - Incoming Transfer Management

    public func acceptIncomingTransfer(_ sid: String, accountID: UUID, range: JingleFileRange? = nil) async throws {
        // Route OOB IQ offers to OOBModule
        if pendingOOBOfferIDs.contains(sid) {
            let oobModule = try await oobModule(for: accountID)
            try await oobModule.acceptOffer(id: sid)
            pendingOOBOfferIDs.remove(sid)
            updateTransferState(forSID: sid, state: .completedTransfer)
            return
        }

        let jingleModule = try await jingleModule(for: accountID)

        try await jingleModule.acceptFileTransfer(sid: sid, range: range)

        let offer = incomingOffers.first { $0.sid == sid }
        guard let offer else { return }

        // Compute effective transfer size when a range is specified
        let expectedSize: Int64
        if let range {
            let offset = range.offset ?? 0
            expectedSize = range.length ?? (offer.fileSize - offset)
        } else {
            expectedSize = offer.fileSize
        }

        Task {
            do {
                try await jingleModule.awaitTransportReady(sid: sid)
                let data = try await jingleModule.receiveFileData(sid: sid, expectedSize: expectedSize)
                switch jingleModule.verifyChecksum(sid: sid, receivedData: data) {
                case .noPendingChecksum, .verified:
                    try? await jingleModule.sendReceivedSessionInfo(sid: sid)
                    log.info("Received \(data.count) bytes via Jingle for sid: \(sid)")
                    updateTransferState(forSID: sid, state: .completedTransfer)
                case let .mismatch(expected, computed):
                    log.error("Checksum mismatch for sid \(sid): expected \(expected), computed \(computed)")
                    try? await jingleModule.terminateSession(sid: sid, reason: .cancel)
                    throw FileTransferError.checksumMismatch(sid: sid)
                case let .unsupportedAlgorithm(algo):
                    log.error("Unsupported checksum algorithm '\(algo)' for sid \(sid)")
                    try? await jingleModule.terminateSession(sid: sid, reason: .cancel)
                    throw FileTransferError.checksumUnsupportedAlgorithm(sid: sid, algo: algo)
                }
            } catch {
                log.warning("Jingle receive failed for sid \(sid): \(error)")
                updateTransferState(forSID: sid, state: .failed(error.localizedDescription))
            }
        }
    }

    /// Fulfills an incoming file request by sending the file at the given URL.
    public func fulfillFileRequest(_ sid: String, fileURL: URL, accountID: UUID) async throws {
        let fileData = try Array(Data(contentsOf: fileURL))
        try await fulfillFileRequest(sid, fileData: fileData, accountID: accountID)
    }

    /// Fulfills an incoming file request with pre-read file data.
    /// Use this overload when the file data must be read before a security-scoped resource is released.
    public func fulfillFileRequest(_ sid: String, fileData: [UInt8], accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)

        try await jingleModule.acceptFileTransfer(sid: sid)
        incomingRequests.removeAll { $0.sid == sid }

        updateTransferState(forSID: sid, state: .connectingTransport)

        Task {
            do {
                try await jingleModule.awaitTransportReady(sid: sid)
                updateTransferState(forSID: sid, state: .transferring(progress: 0))
                try? await jingleModule.sendChecksumSessionInfo(sid: sid, data: fileData)
                try await jingleModule.sendFileData(sid: sid, data: fileData)
                updateTransferState(forSID: sid, state: .completedTransfer)
            } catch {
                log.warning("Jingle file request fulfillment failed for sid \(sid): \(error)")
                updateTransferState(forSID: sid, state: .failed(error.localizedDescription))
            }
        }
    }

    /// Declines an incoming file request.
    public func declineFileRequest(_ sid: String, accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)
        try await jingleModule.declineFileTransfer(sid: sid)
        incomingRequests.removeAll { $0.sid == sid }
    }

    public func declineIncomingTransfer(_ sid: String, accountID: UUID) async throws {
        // Route OOB IQ offers to OOBModule
        if pendingOOBOfferIDs.contains(sid) {
            let oobModule = try await oobModule(for: accountID)
            try await oobModule.rejectOffer(id: sid)
            pendingOOBOfferIDs.remove(sid)
            updateTransferState(forSID: sid, state: .failed("Declined"))
            return
        }

        let jingleModule = try await jingleModule(for: accountID)

        try await jingleModule.declineFileTransfer(sid: sid)
        incomingOffers.removeAll { $0.sid == sid }
    }

    // MARK: - Content-Add Management

    /// Accepts a content-add offer from a peer.
    public func acceptContentAdd(sid: String, contentName: String, accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)
        try await jingleModule.acceptContentAdd(sid: sid, contentName: contentName)
        let id = Self.contentAddID(sid: sid, contentName: contentName)
        incomingContentAddOffers.removeAll { Self.contentAddID(sid: $0.sid, contentName: $0.contentName) == id }
        updateTransferState(forSID: id, state: .connectingTransport)
    }

    /// Rejects a content-add offer from a peer.
    public func rejectContentAdd(sid: String, contentName: String, accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)
        try await jingleModule.rejectContentAdd(sid: sid, contentName: contentName)
        let id = Self.contentAddID(sid: sid, contentName: contentName)
        incomingContentAddOffers.removeAll { Self.contentAddID(sid: $0.sid, contentName: $0.contentName) == id }
        updateTransferState(forSID: id, state: .failed("Declined"))
    }

    /// Removes content from an existing Jingle session.
    public func removeContent(sid: String, contentName: String, accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)
        try await jingleModule.removeContent(sid: sid, contentName: contentName)
        let id = Self.contentAddID(sid: sid, contentName: contentName)
        updateTransferState(forSID: id, state: .failed("Removed"))
    }

    /// Requests a file from a peer (receiver-initiated transfer, XEP-0234).
    public func requestFile(
        from peerJIDString: String, fileName: String, fileSize: Int64,
        mediaType: String? = nil, accountID: UUID
    ) async throws {
        let jingleModule = try await jingleModule(for: accountID)
        guard let peerJID = FullJID.parse(peerJIDString) else {
            throw FileTransferError.jingleFailed("Invalid peer JID: \(peerJIDString)")
        }
        let file = JingleFileDescription(
            name: fileName, size: fileSize,
            mediaType: mediaType ?? "application/octet-stream"
        )
        let sid = try await jingleModule.requestFileTransfer(from: peerJID, file: file)
        let transfer = ActiveTransfer(
            id: UUID(),
            fileName: fileName,
            fileSize: fileSize,
            state: .negotiating,
            method: .jingle,
            direction: .incoming,
            sid: sid
        )
        activeTransfers.append(transfer)
    }

    /// Adds a file to an existing Jingle session (multi-file transfer, XEP-0234).
    public func addFileToSession(sid: String, url: URL, accountID: UUID) async throws {
        let jingleModule = try await jingleModule(for: accountID)
        let attrs: FileAttributes
        do {
            attrs = try readFileAttributes(at: url)
        } catch {
            throw FileTransferError.fileReadFailed(error.localizedDescription)
        }
        let file = JingleFileDescription(
            name: attrs.fileName, size: attrs.fileSize,
            mediaType: attrs.mimeType
        )
        let contentName = try await jingleModule.sendContentAdd(sid: sid, file: file)
        let id = Self.contentAddID(sid: sid, contentName: contentName)
        let transfer = ActiveTransfer(
            id: UUID(),
            fileName: attrs.fileName,
            fileSize: attrs.fileSize,
            state: .negotiating,
            method: .jingle,
            direction: .outgoing,
            sid: id
        )
        activeTransfers.append(transfer)
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

            try? await jingleModule.sendChecksumSessionInfo(sid: sid, data: fileData)
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
        // XEP-0066: Attach OOB element so other clients render file attachments
        var oobX = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
        var urlElement = DuckoXMPP.XMLElement(name: "url")
        urlElement.addText(downloadURL)
        oobX.addChild(urlElement)
        let jid = conversation.jid
        switch conversation.type {
        case .chat:
            try await chatService.sendMessage(to: jid, body: downloadURL, accountID: accountID, additionalElements: [oobX])
        case .groupchat:
            try await chatService.sendGroupMessage(to: jid, body: downloadURL, accountID: accountID, additionalElements: [oobX])
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

    private func oobModule(for accountID: UUID) async throws -> OOBModule {
        guard let client = accountService?.client(for: accountID) else {
            throw FileTransferError.noClient
        }
        guard let module = await client.module(ofType: OOBModule.self) else {
            throw FileTransferError.noClient
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

    /// Updates all content-add transfers belonging to the given session SID.
    private func updateContentAddTransferStates(forSessionSID sid: String, state: TransferState) {
        let prefix = sid + "/"
        for index in activeTransfers.indices where activeTransfers[index].sid?.hasPrefix(prefix) == true {
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
