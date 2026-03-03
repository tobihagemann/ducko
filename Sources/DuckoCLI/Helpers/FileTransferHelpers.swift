import DuckoCore
import DuckoXMPP
import Foundation

struct FileTransferCLIContext {
    let accountID: UUID
    let environment: AppEnvironment
    let formatter: any CLIFormatter
}

func parseTransferMethod(_ string: String?) throws -> FileTransferService.TransferMethod {
    guard let string else { return .auto }
    switch string.lowercased() {
    case "auto":
        return .auto
    case "http":
        return .httpUpload
    case "jingle":
        return .jingle
    default:
        throw CLIError.invalidTransferMethod(string)
    }
}

func sendFileFromCLI(
    filePath: String, recipientJID: BareJID,
    body: String?, method: FileTransferService.TransferMethod = .auto,
    peerJID: String? = nil, context: FileTransferCLIContext
) async throws {
    let fileURL = URL(fileURLWithPath: filePath)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
        throw CLIError.fileNotFound(filePath)
    }
    let fileSize = (attributes[.size] as? Int64) ?? 0
    let fileName = fileURL.lastPathComponent

    let env = context.environment
    let conversation = try await env.chatService.openConversation(for: recipientJID, accountID: context.accountID)
    let downloadURL = try await env.fileTransferService.sendFile(
        url: fileURL, in: conversation, accountID: context.accountID,
        method: method, peerJID: peerJID
    ) { progress in
        printTransferProgress(fileName: fileName, fileSize: fileSize, progress: progress, formatter: context.formatter)
    }

    finishTransferProgress(formatter: context.formatter)
    print(context.formatter.formatFileMessage(fileName: fileName, url: downloadURL, fileSize: fileSize))

    if let body, !body.isEmpty {
        if conversation.type == .groupchat {
            try await env.chatService.sendGroupMessage(to: recipientJID, body: body, accountID: context.accountID)
        } else {
            try await env.chatService.sendMessage(to: recipientJID, body: body, accountID: context.accountID)
        }
    }
}

func printTransferProgress(fileName: String, fileSize: Int64, progress: Double, formatter: any CLIFormatter) {
    let output = formatter.formatTransferProgress(fileName: fileName, fileSize: fileSize, progress: progress)
    if formatter is ANSIFormatter {
        print(output, terminator: "")
        fflush(stdout)
    } else {
        print(output)
    }
}

func finishTransferProgress(formatter: any CLIFormatter) {
    if formatter is ANSIFormatter {
        print() // newline after carriage-return progress bar
    }
}

func handleSendFileREPLCommand(
    _ input: String, context: REPLContext, currentRoom: String?
) async {
    let args = input.dropFirst("/sendfile".count).trimmingCharacters(in: .whitespaces)
    guard !args.isEmpty else {
        print("Usage: /sendfile [jid] <path>")
        return
    }

    let parts = args.split(separator: " ", maxSplits: 1)
    let jidString: String
    let filePath: String

    if parts.count == 2, BareJID.parse(String(parts[0])) != nil {
        // /sendfile <jid> <path>
        jidString = String(parts[0])
        filePath = String(parts[1])
    } else if parts.count == 1, BareJID.parse(args) != nil {
        // /sendfile <jid> — valid JID but missing path
        print("Usage: /sendfile <jid> <path>")
        return
    } else if let roomJID = currentRoom {
        // /sendfile <path> — send to current room
        jidString = roomJID
        filePath = args
    } else {
        print(context.formatter.formatError(CLIError.noConversationTarget))
        return
    }

    guard let recipientJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }

    do {
        let ftContext = FileTransferCLIContext(
            accountID: context.accountID, environment: context.environment, formatter: context.formatter
        )
        try await sendFileFromCLI(
            filePath: filePath, recipientJID: recipientJID,
            body: nil, context: ftContext
        )
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleAcceptREPLCommand(_ input: String, context: REPLContext) async {
    await handleFileTransferREPLCommand(input, prefix: "/accept", verb: "Accepted", context: context) { sid, accountID in
        try await context.environment.fileTransferService.acceptIncomingTransfer(sid, accountID: accountID)
    }
}

func handleDeclineREPLCommand(_ input: String, context: REPLContext) async {
    await handleFileTransferREPLCommand(input, prefix: "/decline", verb: "Declined", context: context) { sid, accountID in
        try await context.environment.fileTransferService.declineIncomingTransfer(sid, accountID: accountID)
    }
}

private func handleFileTransferREPLCommand(
    _ input: String, prefix: String, verb: String, context: REPLContext,
    action: (String, UUID) async throws -> Void
) async {
    let args = input.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    let sid: String
    if args.isEmpty {
        guard let offer = await MainActor.run(body: { context.environment.fileTransferService.incomingOffers.last }) else {
            print(context.formatter.formatError(CLIError.noIncomingOffers))
            return
        }
        sid = offer.sid
    } else {
        sid = args
    }
    do {
        try await action(sid, context.accountID)
        print("\(verb) file transfer: \(sid)")
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleTransfersREPLCommand(context: REPLContext) async {
    let transfers = await MainActor.run { context.environment.fileTransferService.activeTransfers }
    if transfers.isEmpty {
        print("No active transfers.")
        return
    }
    for transfer in transfers {
        let state = formatTransferState(transfer.state)
        let direction = transfer.direction == .outgoing ? "outgoing" : "incoming"
        let method = switch transfer.method {
        case .auto: "auto"
        case .httpUpload: "http"
        case .jingle: "jingle"
        }
        print("  \(transfer.fileName) (\(formatByteCount(transfer.fileSize))) [\(direction)/\(method)] \(state)")
    }
}

private func formatTransferState(_ state: FileTransferService.TransferState) -> String {
    switch state {
    case .requestingSlot: "requesting slot"
    case let .uploading(progress): "uploading \(Int(progress * 100))%"
    case let .completed(url): "completed (\(url))"
    case let .failed(reason): "failed: \(reason)"
    case .negotiating: "negotiating"
    case .connectingTransport: "connecting"
    case let .transferring(progress): "transferring \(Int(progress * 100))%"
    case .awaitingAcceptance: "awaiting acceptance"
    case .completedTransfer: "completed"
    }
}

private func transferProgress(_ state: FileTransferService.TransferState) -> Double {
    switch state {
    case let .uploading(progress): progress
    case let .transferring(progress): progress
    case .completed, .completedTransfer: 1.0
    case .requestingSlot, .negotiating, .connectingTransport, .awaitingAcceptance, .failed: 0.0
    }
}
