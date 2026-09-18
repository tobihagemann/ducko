import ArgumentParser
import DuckoCore
import DuckoXMPP

extension DuckoCLI {
    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a message to a JID"
        )

        @OptionGroup var global: GlobalOptions

        @OptionGroup var accountOption: AccountOption

        @Option(name: .long, help: "Path to a file to upload and send")
        var file: String?

        @Option(name: .long, help: "Transfer method: auto, http, jingle (default: auto)")
        var method: String?

        @Argument(help: "The recipient JID")
        var jid: String

        @Argument(help: "The message body")
        var body: String?

        func validate() throws {
            guard file != nil || body != nil else {
                throw ValidationError("Provide a message body or --file <path>")
            }
        }

        func run() async throws {
            let formatter = global.formatter

            guard let parsedJID = JID.parse(jid) else {
                throw CLIError.invalidJID(jid)
            }
            let recipientJID = parsedJID.bareJID

            try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                if let file {
                    let resolvedMethod = try parseTransferMethod(method)
                    let ftContext = FileTransferCLIContext(
                        accountID: selectedAccount.id, environment: env, formatter: formatter
                    )
                    let peerOverride = resolvedMethod == .jingle ? jid : nil
                    try await sendFileFromCLI(
                        filePath: file, recipientJID: recipientJID,
                        body: body, method: resolvedMethod,
                        peerJID: peerOverride, context: ftContext
                    )
                } else if let body {
                    try await env.chatService.sendMessage(to: recipientJID, body: body, accountID: selectedAccount.id)

                    print(formatter.formatMessage(ChatMessage.displayPlaceholder(
                        fromJID: recipientJID.description, body: body
                    ), accountJID: selectedAccount.jid))
                }
            }
        }
    }
}
