import ArgumentParser
import DuckoCore
import DuckoXMPP
import Foundation

@main
struct DuckoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ducko",
        abstract: "Ducko XMPP client",
        version: "0.1.0",
        subcommands: [
            Send.self,
            Roster.self,
            Presence.self,
            History.self,
            Room.self,
            Account.self,
            Interactive.self
        ],
        defaultSubcommand: Interactive.self
    )
}

// MARK: - Global Options

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: plain, ansi, json")
    var output: OutputFormat?

    var resolvedFormat: OutputFormat {
        output ?? .defaultForTerminal
    }
}

// MARK: - Send

extension DuckoCLI {
    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a message to a JID"
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: .long, help: "Account UUID (uses first account if omitted)")
        var account: String?

        @Argument(help: "The recipient JID")
        var jid: String

        @Argument(help: "The message body")
        var body: String

        func run() async throws {
            let formatter = global.resolvedFormat.makeFormatter()

            guard let recipientJID = BareJID.parse(jid) else {
                throw CLIError.invalidJID(jid)
            }

            let context = try await MainActor.run {
                try CLIBootstrap.setUp(formatter: formatter)
            }
            let env = context.environment

            let selectedAccount = try await resolveAccount(account, environment: env)

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description) else {
                throw CLIError.noPassword
            }

            try await env.accountService.connect(accountID: selectedAccount.id, password: password)
            try await waitForConnected(accountID: selectedAccount.id, environment: env)

            try await env.chatService.sendMessage(to: recipientJID, body: body, accountID: selectedAccount.id)

            print(formatter.formatMessage(ChatMessage(
                id: UUID(),
                conversationID: UUID(),
                fromJID: recipientJID.description,
                body: body,
                timestamp: Date(),
                isOutgoing: true,
                isRead: true,
                isDelivered: false,
                isEdited: false,
                type: "chat"
            )))

            await env.accountService.disconnect(accountID: selectedAccount.id)
        }
    }
}

// MARK: - Interactive

extension DuckoCLI {
    struct Interactive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start interactive REPL mode"
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: .long, help: "Account UUID (uses first account if omitted)")
        var account: String?

        func run() async throws {
            let formatter = global.resolvedFormat.makeFormatter()

            let context = try await MainActor.run {
                try CLIBootstrap.setUp(formatter: formatter)
            }
            let env = context.environment

            let selectedAccount = try await resolveAccount(account, environment: env)

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description) else {
                throw CLIError.noPassword
            }

            try await env.accountService.connect(accountID: selectedAccount.id, password: password)
            try await waitForConnected(accountID: selectedAccount.id, environment: env)

            print("Connected. Type 'help' for commands, 'quit' to exit.")

            // Run readLine loop in Task.detached (blocking I/O must not run on cooperative thread)
            let accountID = selectedAccount.id
            let accountJID = selectedAccount.jid
            await Task.detached {
                await runREPL(formatter: formatter, environment: env, accountID: accountID, accountJID: accountJID)
            }.value
        }
    }
}

// MARK: - Roster

extension DuckoCLI {
    struct Roster: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the contact roster",
            subcommands: [List.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List contacts"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)
                try await waitForRosterLoaded(environment: env)

                // Wait for initial presence stanzas
                try await Task.sleep(for: .seconds(1.5))

                let (groups, presences) = await MainActor.run {
                    (env.rosterService.groups, env.presenceService.contactPresences)
                }

                guard !groups.isEmpty else {
                    print("No contacts in roster.")
                    await env.accountService.disconnect(accountID: selectedAccount.id)
                    return
                }

                printRoster(groups: groups, presences: presences, formatter: formatter)

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }
    }
}

// MARK: - Presence

extension DuckoCLI {
    struct Presence: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Get or set presence status"
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: .long, help: "Account UUID (uses first account if omitted)")
        var account: String?

        @Argument(help: "Status: available, away, xa, dnd, offline")
        var status: String?

        @Argument(help: "Optional status message")
        var message: String?

        func run() async throws {
            let formatter = global.resolvedFormat.makeFormatter()

            let context = try await MainActor.run {
                try CLIBootstrap.setUp(formatter: formatter)
            }
            let env = context.environment

            let selectedAccount = try await resolveAccount(account, environment: env)

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description) else {
                throw CLIError.noPassword
            }

            try await env.accountService.connect(accountID: selectedAccount.id, password: password)
            try await waitForConnected(accountID: selectedAccount.id, environment: env)

            if let status {
                guard let presenceStatus = PresenceService.PresenceStatus(rawValue: status) else {
                    throw CLIError.invalidPresenceStatus(status)
                }
                await applyPresence(presenceStatus, message: message, environment: env, accountID: selectedAccount.id)
                print(formatter.formatPresence(jid: selectedAccount.jid, status: presenceStatus.rawValue, message: message))
            } else {
                let (myPresence, myMessage) = await MainActor.run {
                    (env.presenceService.myPresence, env.presenceService.myStatusMessage)
                }
                print(formatter.formatPresence(jid: selectedAccount.jid, status: myPresence.rawValue, message: myMessage))
            }

            await env.accountService.disconnect(accountID: selectedAccount.id)
        }
    }
}

// MARK: - Stubs

extension DuckoCLI {
    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "View message history"
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "The JID to view history for")
        var jid: String

        func run() async throws {
            print("history: not yet implemented")
        }
    }

    struct Room: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage multi-user chat rooms",
            subcommands: [Join.self, Leave.self, ListRooms.self],
            defaultSubcommand: ListRooms.self
        )

        struct Join: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Join a room"
            )

            @OptionGroup var global: GlobalOptions

            @Argument(help: "The room JID")
            var jid: String

            func run() async throws {
                print("room join: not yet implemented")
            }
        }

        struct Leave: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Leave a room"
            )

            @OptionGroup var global: GlobalOptions

            @Argument(help: "The room JID")
            var jid: String

            func run() async throws {
                print("room leave: not yet implemented")
            }
        }

        struct ListRooms: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List joined rooms"
            )

            @OptionGroup var global: GlobalOptions

            func run() async throws {
                print("room list: not yet implemented")
            }
        }
    }

    struct Account: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage XMPP accounts",
            subcommands: [List.self, Add.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List configured accounts"
            )

            @OptionGroup var global: GlobalOptions

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                try await env.accountService.loadAccounts()
                let accounts = await MainActor.run { env.accountService.accounts }

                guard !accounts.isEmpty else {
                    print("No accounts configured.")
                    return
                }

                for account in accounts {
                    print(formatter.formatAccount(account))
                }
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a new XMPP account"
            )

            @Argument(help: "The bare JID (e.g. alice@example.com)")
            var jid: String

            func run() async throws {
                guard BareJID.parse(jid) != nil else {
                    throw CLIError.invalidJID(jid)
                }

                guard let password = CredentialHelper.getPassword() else {
                    throw CLIError.noPassword
                }

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: PlainFormatter())
                }
                let env = context.environment

                let accountID = try await env.accountService.createAccount(jidString: jid)
                do {
                    try await env.accountService.connect(accountID: accountID, password: password)
                    try await waitForConnected(accountID: accountID, environment: env)
                    await env.accountService.savePasswordToKeychain(accountID: accountID)
                    await env.accountService.disconnect(accountID: accountID)
                } catch {
                    try? await env.accountService.deleteAccount(accountID)
                    throw error
                }

                print("Account added: \(jid)")
            }
        }
    }
}

// MARK: - REPL

private func runREPL(formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID, accountJID: BareJID) async {
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        if trimmed == "quit" || trimmed == "exit" {
            await environment.accountService.disconnect(accountID: accountID)
            Foundation.exit(0)
        }

        if trimmed == "help" {
            print("Commands:")
            print("  send <jid> <message>     Send a message")
            print("  /roster                  Show contacts with presence")
            print("  /status [status] [msg]   Get or set presence")
            print("  /who                     Show online contacts")
            print("  help                     Show this help")
            print("  quit                     Disconnect and exit")
            continue
        }

        if trimmed.hasPrefix("send ") {
            await handleSendCommand(trimmed, formatter: formatter, environment: environment, accountID: accountID)
            continue
        }

        if trimmed == "/roster" {
            await handleRosterCommand(formatter: formatter, environment: environment)
            continue
        }

        if trimmed == "/status" || trimmed.hasPrefix("/status ") {
            await handleStatusCommand(trimmed, formatter: formatter, environment: environment, accountID: accountID, accountJID: accountJID)
            continue
        }

        if trimmed == "/who" {
            await handleWhoCommand(formatter: formatter, environment: environment)
            continue
        }

        print("Unknown command: \(trimmed). Type 'help' for commands.")
    }

    // stdin closed
    await environment.accountService.disconnect(accountID: accountID)
    Foundation.exit(0)
}

private func handleSendCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID
) async {
    let parts = input.dropFirst(5).split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print(formatter.formatError(CLIError.invalidJID("usage: send <jid> <message>")))
        return
    }
    let jidString = String(parts[0])
    let messageBody = String(parts[1])

    guard let recipientJID = BareJID.parse(jidString) else {
        print(formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }

    do {
        try await environment.chatService.sendMessage(to: recipientJID, body: messageBody, accountID: accountID)
    } catch {
        print(formatter.formatError(error))
    }
}

private func handleRosterCommand(formatter: any CLIFormatter, environment: AppEnvironment) async {
    let (groups, presences) = await MainActor.run {
        (environment.rosterService.groups, environment.presenceService.contactPresences)
    }

    guard !groups.isEmpty else {
        print("No contacts in roster.")
        return
    }

    printRoster(groups: groups, presences: presences, formatter: formatter)
}

private func handleStatusCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID, accountJID: BareJID
) async {
    let args = input.dropFirst("/status".count).trimmingCharacters(in: .whitespaces)

    if args.isEmpty {
        let (myPresence, myMessage) = await MainActor.run {
            (environment.presenceService.myPresence, environment.presenceService.myStatusMessage)
        }
        print(formatter.formatPresence(jid: accountJID, status: myPresence.rawValue, message: myMessage))
        return
    }

    let parts = args.split(separator: " ", maxSplits: 1)
    let statusString = String(parts[0])
    let message: String? = parts.count > 1 ? String(parts[1]) : nil

    guard let presenceStatus = PresenceService.PresenceStatus(rawValue: statusString) else {
        print(formatter.formatError(CLIError.invalidPresenceStatus(statusString)))
        return
    }

    await applyPresence(presenceStatus, message: message, environment: environment, accountID: accountID)

    print(formatter.formatPresence(jid: accountJID, status: presenceStatus.rawValue, message: message))
}

private func handleWhoCommand(formatter: any CLIFormatter, environment: AppEnvironment) async {
    let (groups, presences) = await MainActor.run {
        (environment.rosterService.groups, environment.presenceService.contactPresences)
    }

    // Deduplicate contacts that appear in multiple groups
    var seen = Set<String>()
    let uniqueContacts = groups.flatMap(\.contacts).filter { seen.insert($0.jid.description).inserted }
    let onlineContacts = uniqueContacts
        .compactMap { contact -> (Contact, PresenceService.PresenceStatus)? in
            guard let presence = presences[contact.jid], presence != .offline else { return nil }
            return (contact, presence)
        }
        .sorted { $0.0.jid.description < $1.0.jid.description }

    guard !onlineContacts.isEmpty else {
        print("No contacts online.")
        return
    }

    for (contact, presence) in onlineContacts {
        print(formatter.formatContactWithPresence(contact, presence: presence))
    }
}

private func printRoster(groups: [ContactGroup], presences: [BareJID: PresenceService.PresenceStatus], formatter: any CLIFormatter) {
    for group in groups {
        print(formatter.formatGroupHeader(group))
        for contact in group.contacts {
            let presence = presences[contact.jid]
            print(formatter.formatContactWithPresence(contact, presence: presence))
        }
    }
}

private func applyPresence(
    _ presenceStatus: PresenceService.PresenceStatus,
    message: String?,
    environment: AppEnvironment,
    accountID: UUID
) async {
    if presenceStatus == .offline {
        await MainActor.run {
            environment.presenceService.goOffline(accountID: accountID)
        }
    } else {
        await environment.presenceService.setPresence(presenceStatus, message: message, accountID: accountID)
    }
}

// MARK: - Helpers

private func resolveAccount(_ accountIDString: String?, environment: AppEnvironment) async throws -> DuckoCore.Account {
    try await environment.accountService.loadAccounts()
    let accounts = await MainActor.run { environment.accountService.accounts }
    guard !accounts.isEmpty else {
        throw CLIError.noAccounts
    }

    if let accountIDString {
        guard let uuid = UUID(uuidString: accountIDString),
              let found = accounts.first(where: { $0.id == uuid })
        else {
            throw CLIError.accountNotFound(accountIDString)
        }
        return found
    }
    return accounts[0]
}

private func waitForConnected(accountID: UUID, environment: AppEnvironment) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        let state = await MainActor.run { environment.accountService.connectionStates[accountID] }
        switch state {
        case .connected:
            return
        case let .error(message):
            throw CLIError.connectionFailed(message)
        case .disconnected, .connecting, .none:
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    throw CLIError.connectionTimeout
}

private func waitForRosterLoaded(environment: AppEnvironment) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
        let groups = await MainActor.run { environment.rosterService.groups }
        if !groups.isEmpty {
            return
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    // Empty roster — timeout expires gracefully
}
