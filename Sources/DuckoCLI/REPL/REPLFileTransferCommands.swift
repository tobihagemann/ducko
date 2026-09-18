import DuckoCore
import DuckoXMPP
import Foundation

func handleSendFileREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?) async {
    guard !arguments.isEmpty else {
        print("Usage: /sendfile [jid] <path>")
        return
    }

    let jidString: String
    let filePath: String
    switch parseSendFileArgs(arguments, currentRoom: currentRoom) {
    case let .send(target, path):
        jidString = target
        filePath = path
    case .missingPath:
        print("Usage: /sendfile <jid> <path>")
        return
    case .noTarget:
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

func handleAcceptREPLCommand(_ arguments: String, context: REPLContext) async {
    // `downloadsDirectory` is nonisolated, but reaching the service through `environment` is not.
    let downloadsPath = await MainActor.run { context.environment.fileTransferService.downloadsDirectory.path }
    await handleFileTransferREPLCommand(
        arguments, context: context,
        confirmation: { "Accepted file transfer: \($0), saving to \(downloadsPath)" },
        action: { offerID, accountID in
            try await context.environment.fileTransferService.acceptIncomingTransfer(offerID, accountID: accountID)
        }
    )
}

func handleDeclineREPLCommand(_ arguments: String, context: REPLContext) async {
    await handleFileTransferREPLCommand(
        arguments, context: context,
        confirmation: { "Declined file transfer: \($0)" },
        action: { offerID, accountID in
            try await context.environment.fileTransferService.declineIncomingTransfer(offerID, accountID: accountID)
        }
    )
}

private func handleFileTransferREPLCommand(
    _ arguments: String, context: REPLContext,
    confirmation: (String) -> String,
    action: (String, UUID) async throws -> Void
) async {
    let offerID: String
    if arguments.isEmpty {
        // The same projection the GUI banner shows, so a link offer can be taken here too. The action runs on this
        // session's account, so the newest offer is taken from that account's.
        let latest = await MainActor.run {
            context.environment.fileTransferService.viewIncomingOffers.last { $0.accountID == context.accountID }?.offerID
        }
        guard let latest else {
            print(context.formatter.formatError(CLIError.noIncomingOffers))
            return
        }
        offerID = latest
    } else {
        offerID = arguments
    }
    do {
        try await action(offerID, context.accountID)
        print(confirmation(offerID))
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
        let sidSuffix = if let sid = transfer.sid, transfer.method == .jingle { " (sid: \(sid))" } else { "" }
        print("  \(transfer.fileName) (\(formatByteCount(transfer.fileSize))) [\(direction)/\(method)] \(state)\(sidSuffix)")
    }
}
