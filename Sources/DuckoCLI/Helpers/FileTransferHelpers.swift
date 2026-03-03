import DuckoCore
import DuckoXMPP
import Foundation

struct FileTransferCLIContext {
    let accountID: UUID
    let environment: AppEnvironment
    let formatter: any CLIFormatter
}

func sendFileFromCLI(
    filePath: String, recipientJID: BareJID,
    body: String?, context: FileTransferCLIContext
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
        url: fileURL, in: conversation, accountID: context.accountID
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
