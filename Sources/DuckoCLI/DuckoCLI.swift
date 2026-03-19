import ArgumentParser
import DuckoCore
import DuckoXMPP
import Foundation
import UniformTypeIdentifiers

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
            Profile.self,
            History.self,
            Room.self,
            Bookmarks.self,
            Avatar.self,
            Account.self,
            ServerInfoCommand.self,
            OMEMO.self,
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
            let formatter = global.resolvedFormat.makeFormatter()

            guard let parsedJID = JID.parse(jid) else {
                throw CLIError.invalidJID(jid)
            }
            let recipientJID = parsedJID.bareJID

            let context = try await MainActor.run {
                try CLIBootstrap.setUp(formatter: formatter)
            }
            let env = context.environment

            let selectedAccount = try await resolveAccount(account, environment: env)

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                throw CLIError.noPassword
            }

            try await env.accountService.connect(accountID: selectedAccount.id, password: password)
            try await waitForConnected(accountID: selectedAccount.id, environment: env)

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
                try CLIBootstrap.setUp(formatter: formatter, isInteractive: true)
            }
            let env = context.environment

            let selectedAccount = try await resolveAccount(account, environment: env)

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
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
            subcommands: [List.self, Add.self, Remove.self],
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

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
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

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a contact to the roster"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The JID to add")
            var jid: String

            @Option(name: .long, help: "Display name for the contact")
            var name: String?

            @Option(name: .long, help: "Group for the contact")
            var group: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                guard let bareJID = BareJID.parse(jid) else {
                    throw CLIError.invalidJID(jid)
                }

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let groups = group.map { [$0] } ?? []
                try await env.rosterService.addContact(jid: bareJID, name: name, groups: groups, accountID: selectedAccount.id)

                print("Added \(jid) to roster.")

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove a contact from the roster"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The JID to remove")
            var jid: String

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                guard let bareJID = BareJID.parse(jid) else {
                    throw CLIError.invalidJID(jid)
                }

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)
                try await waitForRosterLoaded(environment: env)

                try await env.rosterService.removeContact(jidString: bareJID.description, accountID: selectedAccount.id)

                print("Removed \(jid) from roster.")

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

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
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

// MARK: - Profile

extension DuckoCLI {
    struct Profile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "View own vCard profile"
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

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                throw CLIError.noPassword
            }

            try await env.accountService.connect(accountID: selectedAccount.id, password: password)
            try await waitForConnected(accountID: selectedAccount.id, environment: env)

            let output = await fetchAndFormatProfile(
                environment: env, accountID: selectedAccount.id, formatter: formatter
            )
            print(output)

            await env.accountService.disconnect(accountID: selectedAccount.id)
        }
    }
}

// MARK: - History

extension DuckoCLI {
    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "View message history"
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: .long, help: "Account UUID (uses first account if omitted)")
        var account: String?

        @Argument(help: "The JID to view history for")
        var jid: String

        @Option(name: .long, help: "Maximum number of messages (default: 20)")
        var limit: Int = 20

        @Option(name: .long, help: "Show messages before this ISO 8601 date")
        var before: String?

        @Option(name: .long, help: "Filter messages by keyword (case-insensitive)")
        var search: String?

        @Flag(name: .long, help: "Fetch from server when local history is empty (requires connection)")
        var server: Bool = false

        func run() async throws {
            let formatter = global.resolvedFormat.makeFormatter()

            guard let bareJID = BareJID.parse(jid) else {
                throw CLIError.invalidJID(jid)
            }

            let context = try await MainActor.run {
                try CLIBootstrap.setUp(formatter: formatter)
            }
            let env = context.environment

            let selectedAccount = try await resolveAccount(account, environment: env)

            if let search {
                let messages = try await searchHistory(
                    jid: bareJID, query: search, limit: limit,
                    environment: env, accountID: selectedAccount.id
                )
                printHistory(messages, formatter: formatter, accountJID: selectedAccount.jid)
                return
            }

            let beforeDate = try parseBeforeDate(before)
            var messages = try await fetchHistory(
                jid: bareJID, before: beforeDate, limit: limit,
                environment: env, accountID: selectedAccount.id
            )

            if server, messages.isEmpty {
                let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore)
                guard let password else { throw CLIError.noPassword }
                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)
                do {
                    let (serverMessages, _) = try await env.chatService.fetchServerHistory(
                        jid: bareJID, accountID: selectedAccount.id, before: beforeDate, limit: limit
                    )
                    messages = serverMessages
                } catch {
                    await env.accountService.disconnect(accountID: selectedAccount.id)
                    throw error
                }
                await env.accountService.disconnect(accountID: selectedAccount.id)
            }

            printHistory(messages, formatter: formatter, accountJID: selectedAccount.jid)
        }
    }
}

// MARK: - Room

extension DuckoCLI {
    struct Room: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage multi-user chat rooms",
            subcommands: [ListRooms.self, Join.self, Members.self, Send.self],
            defaultSubcommand: ListRooms.self
        )

        struct ListRooms: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "Discover available rooms on a MUC service"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Option(name: .long, help: "MUC service JID (auto-discovered if omitted)")
            var service: String?

            @Option(name: [.customShort("q"), .long], help: "Search for channels by keyword (XEP-0433)")
            var search: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                if let search {
                    let channels = try await env.chatService.searchChannels(keyword: search, accountID: selectedAccount.id).channels
                    for channel in channels {
                        print(formatter.formatSearchedChannel(channel))
                    }
                    if channels.isEmpty {
                        print("No channels found.")
                    }
                } else {
                    let serviceJID: String
                    if let service {
                        serviceJID = service
                    } else {
                        guard let discovered = await env.chatService.discoverMUCService(accountID: selectedAccount.id) else {
                            throw CLIError.noMUCService
                        }
                        serviceJID = discovered
                    }

                    let rooms = try await env.chatService.discoverRooms(on: serviceJID, accountID: selectedAccount.id)
                    printDiscoveredRooms(rooms, formatter: formatter)
                }

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Join: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Join a room and monitor messages"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The room JID")
            var jid: String

            @Option(name: .long, help: "Nickname to use (defaults to local part of account JID)")
            var nickname: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter, isInteractive: true)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let nick = nickname ?? defaultNickname(for: selectedAccount)
                try await env.chatService.joinRoom(jidString: jid, nickname: nick, accountID: selectedAccount.id)
                try await waitForRoomJoined(roomJID: jid, environment: env)

                let participantCount = await MainActor.run { env.chatService.participantCount(forRoomJIDString: jid) }
                print(formatter.formatRoomJoinedConfirmation(room: jid, nickname: nick, participantCount: participantCount, subject: nil))
                print("Type 'send <message>' to send, 'quit' to leave.")

                let accountID = selectedAccount.id
                let roomJID = jid
                await Task.detached {
                    await runRoomLoop(roomJID: roomJID, formatter: formatter, environment: env, accountID: accountID)
                }.value
            }
        }

        struct Members: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show room occupants"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The room JID")
            var jid: String

            @Option(name: .long, help: "Nickname to use (defaults to local part of account JID)")
            var nickname: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let nick = nickname ?? defaultNickname(for: selectedAccount)
                try await env.chatService.joinRoom(jidString: jid, nickname: nick, accountID: selectedAccount.id)
                try await waitForRoomJoined(roomJID: jid, environment: env)

                await printRoomMembers(jidString: jid, environment: env, formatter: formatter)

                try await env.chatService.leaveRoom(jidString: jid, accountID: selectedAccount.id)
                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Send: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Send a message to a room"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The room JID")
            var jid: String

            @Argument(help: "The message body")
            var body: String

            @Option(name: .long, help: "Nickname to use (defaults to local part of account JID)")
            var nickname: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let nick = nickname ?? defaultNickname(for: selectedAccount)
                try await env.chatService.joinRoom(jidString: jid, nickname: nick, accountID: selectedAccount.id)
                try await waitForRoomJoined(roomJID: jid, environment: env)

                try await env.chatService.sendGroupMessage(toJIDString: jid, body: body, accountID: selectedAccount.id)

                try await env.chatService.leaveRoom(jidString: jid, accountID: selectedAccount.id)
                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }
    }

    struct Bookmarks: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bookmarks",
            abstract: "Manage PEP bookmarks",
            subcommands: [List.self, Add.self, Remove.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List server-side bookmarks"
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

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                await env.bookmarksService.loadBookmarks(accountID: selectedAccount.id)
                let bookmarks = await MainActor.run { env.bookmarksService.bookmarks }

                guard !bookmarks.isEmpty else {
                    print("No bookmarks.")
                    await env.accountService.disconnect(accountID: selectedAccount.id)
                    return
                }

                for bookmark in bookmarks {
                    print(formatter.formatBookmark(bookmark))
                }

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a bookmark"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The room JID")
            var jid: String

            @Option(name: .long, help: "Display name for the room")
            var name: String?

            @Option(name: .long, help: "Nickname to use in the room")
            var nick: String?

            @Flag(name: .long, help: "Auto-join room on connect")
            var autojoin = false

            @Option(name: .long, help: "Room password")
            var password: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let pw = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: pw)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let bookmark = RoomBookmark(
                    jidString: jid,
                    name: name,
                    autojoin: autojoin,
                    nickname: nick,
                    password: password
                )
                try await env.bookmarksService.addBookmark(bookmark, accountID: selectedAccount.id)

                print("Added bookmark for \(jid).")

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove a bookmark"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The room JID to remove")
            var jid: String

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                try await env.bookmarksService.removeBookmark(jidString: jid, accountID: selectedAccount.id)

                print("Removed bookmark for \(jid).")

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }
    }

    struct Avatar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "avatar",
            abstract: "Manage user avatars",
            subcommands: [Get.self, Set.self]
        )

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Fetch and save a contact's avatar"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The JID to fetch the avatar from")
            var jid: String

            @Option(name: .long, help: "File path to save the avatar (default: <jid>.png)")
            var save: String?

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                guard let bareJID = BareJID.parse(jid) else {
                    throw CLIError.invalidJID(jid)
                }

                guard let avatar = await env.avatarService.fetchAvatar(for: bareJID, accountID: selectedAccount.id) else {
                    print("No avatar found for \(jid).")
                    await env.accountService.disconnect(accountID: selectedAccount.id)
                    return
                }

                let ext = avatar.mimeType.contains("png") ? "png" : "jpg"
                let filePath = save ?? "\(jid).\(ext)"
                try avatar.data.write(to: URL(fileURLWithPath: filePath))

                print("Saved avatar to \(filePath)")
                print("Hash: \(avatar.hash)")
                print("Type: \(avatar.mimeType)")
                print("Size: \(avatar.data.count) bytes")

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Publish own avatar from an image file"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "Path to the image file (PNG recommended)")
            var path: String

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                let url = URL(fileURLWithPath: path)
                let imageData = try Data(contentsOf: url)

                let ext = url.pathExtension
                let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png"

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                try await env.avatarService.publishAvatar(imageData: imageData, mimeType: mimeType, accountID: selectedAccount.id)

                let hash = await MainActor.run { env.avatarService.ownAvatarHash ?? "unknown" }
                print("Avatar published successfully.")
                print("Hash: \(hash)")
                print("Size: \(imageData.count) bytes")

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }
    }

    struct Account: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage XMPP accounts",
            subcommands: [List.self, Add.self, Delete.self, Register.self],
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
                    await env.accountService.savePassword(accountID: accountID)
                    await env.accountService.disconnect(accountID: accountID)
                } catch {
                    try? await env.accountService.deleteAccount(accountID)
                    throw error
                }

                print("Account added: \(jid)")
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete an XMPP account"
            )

            @Argument(help: "The bare JID of the account to delete")
            var jid: String

            func run() async throws {
                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: PlainFormatter())
                }
                let env = context.environment

                try await env.accountService.loadAccounts()
                let accounts = await MainActor.run { env.accountService.accounts }

                guard let account = accounts.first(where: { $0.jid.description == jid }) else {
                    throw CLIError.accountNotFound(jid)
                }

                try await env.accountService.deleteAccount(account.id)
                print("Account deleted: \(jid)")
            }
        }

        struct Register: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Register a new account on a server via XEP-0077"
            )

            @Option(name: .long, help: "Server domain (e.g. example.com)")
            var server: String

            @Option(name: .long, help: "Username for the new account")
            var username: String

            @Option(name: .long, help: "Password for the new account (prompted if omitted)")
            var password: String?

            @Option(name: .long, help: "Email address (optional)")
            var email: String?

            func run() async throws {
                guard let resolvedPassword = password ?? CredentialHelper.getPassword() else {
                    throw CLIError.noPassword
                }

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: PlainFormatter())
                }
                let env = context.environment

                let accountID = try await env.accountService.registerAccount(
                    domain: server,
                    username: username,
                    password: resolvedPassword,
                    email: email
                )
                await env.accountService.disconnect(accountID: accountID)
                print("Account registered: \(username)@\(server)")
            }
        }
    }

    struct ServerInfoCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "server-info",
            abstract: "Show server contact information (XEP-0157)"
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

            guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                throw CLIError.noPassword
            }

            try await env.accountService.connect(accountID: selectedAccount.id, password: password)
            try await waitForConnected(accountID: selectedAccount.id, environment: env)

            let info = try await env.accountService.fetchServerInfo(accountID: selectedAccount.id)
            print(formatter.formatServerInfo(info))

            await env.accountService.disconnect(accountID: selectedAccount.id)
        }
    }

    // MARK: - OMEMO

    struct OMEMO: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "omemo",
            abstract: "OMEMO encryption management",
            subcommands: [Fingerprint.self, Devices.self, Trust.self, Untrust.self]
        )

        struct Fingerprint: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Display your own OMEMO device fingerprint"
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

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let fingerprint = await env.omemoService.ownFingerprint(accountID: selectedAccount.id)
                if let fingerprint {
                    print(formatFingerprintHex(fingerprint))
                } else {
                    print("No OMEMO identity found.")
                }

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Devices: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List a contact's OMEMO devices with trust status"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The contact JID")
            var jid: String

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let devices = await env.omemoService.deviceInfoList(for: jid, accountID: selectedAccount.id)
                if devices.isEmpty {
                    print("No known OMEMO devices for \(jid).")
                } else {
                    for device in devices {
                        let fp = device.fingerprint.isEmpty ? "(no fingerprint)" : formatFingerprintHex(device.fingerprint)
                        print("  \(device.deviceID)  \(fp)  [\(device.trustLevel.rawValue)]")
                    }
                }

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Trust: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Trust a contact's OMEMO device"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The contact JID")
            var jid: String

            @Argument(help: "The device ID to trust")
            var deviceID: UInt32

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                // Look up existing trust record for fingerprint
                let devices = await env.omemoService.deviceInfoList(for: jid, accountID: selectedAccount.id)
                guard let device = devices.first(where: { $0.deviceID == deviceID }) else {
                    print("Device \(deviceID) not found for \(jid).")
                    await env.accountService.disconnect(accountID: selectedAccount.id)
                    return
                }

                try await env.omemoService.trustDevice(
                    accountID: selectedAccount.id, peerJID: jid,
                    deviceID: deviceID, fingerprint: device.fingerprint
                )
                print("Trusted device \(deviceID) for \(jid).")

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }

        struct Untrust: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Untrust a contact's OMEMO device"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Account UUID (uses first account if omitted)")
            var account: String?

            @Argument(help: "The contact JID")
            var jid: String

            @Argument(help: "The device ID to untrust")
            var deviceID: UInt32

            func run() async throws {
                let formatter = global.resolvedFormat.makeFormatter()

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                let selectedAccount = try await resolveAccount(account, environment: env)

                guard let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                try await env.omemoService.untrustDevice(
                    accountID: selectedAccount.id, peerJID: jid, deviceID: deviceID
                )
                print("Untrusted device \(deviceID) for \(jid).")

                await env.accountService.disconnect(accountID: selectedAccount.id)
            }
        }
    }
}

// MARK: - Room Loop

private func runRoomLoop(roomJID: String, formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID) async {
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        if trimmed == "quit" || trimmed == "exit" {
            break
        }

        if trimmed.hasPrefix("send ") {
            let body = String(trimmed.dropFirst(5))
            do {
                try await environment.chatService.sendGroupMessage(toJIDString: roomJID, body: body, accountID: accountID)
            } catch {
                print(formatter.formatError(error))
            }
        } else {
            print("Commands: send <message>, quit")
        }
    }

    // quit or stdin closed
    try? await environment.chatService.leaveRoom(jidString: roomJID, accountID: accountID)
    await environment.accountService.disconnect(accountID: accountID)
    Foundation.exit(0)
}

// MARK: - REPL

private func runREPL(formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID, accountJID: BareJID) async {
    let context = REPLContext(formatter: formatter, environment: environment, accountID: accountID, accountJID: accountJID)
    var currentRoom: String?

    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        if trimmed == "quit" || trimmed == "exit" {
            await leaveCurrentRoom(currentRoom, environment: environment, accountID: accountID)
            await environment.accountService.disconnect(accountID: accountID)
            Foundation.exit(0)
        }

        if trimmed == "help" {
            printREPLHelp()
            continue
        }

        let result = await dispatchREPLCommand(trimmed, context: context, currentRoom: currentRoom)
        if result.handled {
            if let updated = result.updatedCurrentRoom {
                currentRoom = updated
            }
        } else {
            print("Unknown command: \(trimmed). Type 'help' for commands.")
        }
    }

    // stdin closed
    await leaveCurrentRoom(currentRoom, environment: environment, accountID: accountID)
    await environment.accountService.disconnect(accountID: accountID)
    Foundation.exit(0)
}

private func printREPLHelp() {
    print("Commands:")
    print("  send <jid> <message>     Send a message")
    print("  /roster                  Show contacts with presence")
    print("  /status [status] [msg]   Get or set presence")
    print("  /who                     Show online contacts")
    print("  /add <jid> [name]        Add contact to roster")
    print("  /remove <jid>            Remove contact from roster")
    print("  /history <jid> [limit]   Show message history")
    print("  /profile                 View own vCard profile")
    print("  /reply <jid> <message>   Reply to last incoming message")
    print("  /retract <jid>           Retract last sent message")
    print("  /edit <jid> <new-body>   Edit last sent message")
    print("  /search <jid> <query>    Search message history")
    print("  /approve <jid>           Approve subscription request")
    print("  /deny <jid>              Deny subscription request")
    print("  /directed-presence <jid> Send directed presence to a JID")
    print("  /join <room> [nick]      Join a MUC room")
    print("  /leave [room]            Leave a MUC room")
    print("  /members [room]          Show room occupants")
    print("  /topic [room] [text]     View or set room topic")
    print("  /nick <nickname>         Change nickname in current room")
    print("  /destroy [reason]        Destroy current room")
    print("  /voice grant|revoke <n>  Grant/revoke voice")
    print("  /affiliations [type]     List affiliations")
    print("  /config                  Show room config")
    print("  /moderate [reason]       Moderate last message in room")
    print("  /sendfile [jid] <path>   Send a file")
    print("  /accept [sid]            Accept incoming file transfer")
    print("  /decline [sid]           Decline incoming file transfer")
    print("  /fulfill [sid] <path>    Fulfill incoming file request")
    print("  /transfers               List active transfers")
    print("  /rooms [service]         Discover available rooms")
    print("  /avatar [jid]            View avatar info (own or contact's)")
    print("  /connection-info         Show TLS connection info")
    print("  /encrypt <jid> on|off    Toggle OMEMO encryption for a conversation")
    print("  /pref chatstates on|off  Toggle chat state notifications")
    print("  /pref markers on|off      Toggle displayed markers (read receipts)")
    print("  help                     Show this help")
    print("  quit                     Disconnect and exit")
}

struct REPLContext {
    let formatter: any CLIFormatter
    let environment: AppEnvironment
    let accountID: UUID
    let accountJID: BareJID
}

private struct REPLDispatchResult {
    let handled: Bool
    /// `nil` = no change, `.some(nil)` = clear, `.some(value)` = set
    let updatedCurrentRoom: String??
}

private func dispatchREPLCommand(
    _ input: String, context: REPLContext, currentRoom: String?
) async -> REPLDispatchResult {
    let formatter = context.formatter
    let environment = context.environment
    let accountID = context.accountID
    let accountJID = context.accountJID
    if input.hasPrefix("send ") {
        await handleSendCommand(input, formatter: formatter, environment: environment, accountID: accountID)
    } else if input == "/roster" {
        await handleRosterCommand(formatter: formatter, environment: environment)
    } else if input == "/status" || input.hasPrefix("/status ") {
        await handleStatusCommand(input, formatter: formatter, environment: environment, accountID: accountID, accountJID: accountJID)
    } else if input == "/who" {
        await handleWhoCommand(formatter: formatter, environment: environment)
    } else if input == "/sendfile" || input.hasPrefix("/sendfile ")
        || input == "/accept" || input.hasPrefix("/accept ")
        || input == "/decline" || input.hasPrefix("/decline ")
        || input == "/fulfill" || input.hasPrefix("/fulfill ")
        || input == "/transfers" {
        await dispatchFileTransferREPLCommand(input, context: context, currentRoom: currentRoom)
    } else if isMiscREPLCommand(input) {
        await dispatchMiscREPLCommand(input, context: context)
    } else {
        return await dispatchRoomREPLCommand(input, context: context, currentRoom: currentRoom)
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func isMiscREPLCommand(_ input: String) -> Bool {
    input.hasPrefix("/add ") || input.hasPrefix("/remove ")
        || input.hasPrefix("/approve ") || input.hasPrefix("/deny ")
        || input == "/history" || input.hasPrefix("/history ")
        || input == "/profile" || input == "/connection-info"
        || input == "/avatar" || input.hasPrefix("/avatar ")
        || input.hasPrefix("/reply ") || input.hasPrefix("/search ")
        || input.hasPrefix("/retract ")
        || input.hasPrefix("/edit ")
        || input.hasPrefix("/encrypt ")
        || input.hasPrefix("/pref ")
        || input.hasPrefix("/directed-presence ")
}

private func dispatchMiscREPLCommand(
    _ input: String, context: REPLContext
) async {
    let formatter = context.formatter
    let environment = context.environment
    let accountID = context.accountID
    let accountJID = context.accountJID
    if input.hasPrefix("/add ") {
        await handleAddCommand(input, formatter: formatter, environment: environment, accountID: accountID)
    } else if input.hasPrefix("/remove ") {
        await handleJIDCommand(
            input, prefix: "/remove ", successMessage: "Removed {jid} from roster.",
            formatter: formatter
        ) { jid in
            try await environment.rosterService.removeContact(jidString: jid, accountID: accountID)
        }
    } else if input.hasPrefix("/approve ") {
        await handleJIDCommand(
            input, prefix: "/approve ", successMessage: "Approved subscription from {jid}.",
            formatter: formatter
        ) { jid in
            try await environment.rosterService.approveSubscription(jidString: jid, accountID: accountID)
        }
    } else if input.hasPrefix("/deny ") {
        await handleJIDCommand(
            input, prefix: "/deny ", successMessage: "Denied subscription from {jid}.",
            formatter: formatter
        ) { jid in
            try await environment.rosterService.denySubscription(jidString: jid, accountID: accountID)
        }
    } else if input == "/history" || input.hasPrefix("/history ") {
        await handleHistoryCommand(input, formatter: formatter, environment: environment, accountID: accountID, accountJID: accountJID)
    } else if input.hasPrefix("/directed-presence ") {
        let jidString = input.dropFirst("/directed-presence ".count).trimmingCharacters(in: .whitespaces)
        guard JID.parse(jidString) != nil else {
            print(formatter.formatError(CLIError.invalidJID(jidString)))
            return
        }
        do {
            try await environment.presenceService.sendDirectedPresence(to: jidString, accountID: accountID)
            print("Sent directed presence to \(jidString).")
        } catch {
            print(formatter.formatError(error))
        }
    } else {
        await dispatchInfoREPLCommand(input, context: context)
    }
}

private func dispatchInfoREPLCommand(
    _ input: String, context: REPLContext
) async {
    if input == "/profile" {
        await handleProfileREPLCommand(context: context)
    } else if input == "/connection-info" {
        await handleConnectionInfoREPLCommand(context: context)
    } else if input.hasPrefix("/reply ") {
        await handleReplyREPLCommand(input, context: context)
    } else if input.hasPrefix("/search ") {
        await handleSearchREPLCommand(input, context: context)
    } else if input == "/avatar" || input.hasPrefix("/avatar ") {
        await handleAvatarREPLCommand(input, context: context)
    } else if input.hasPrefix("/retract ") {
        await handleRetractREPLCommand(input, context: context)
    } else if input.hasPrefix("/edit ") {
        await handleEditREPLCommand(input, context: context)
    } else if input.hasPrefix("/encrypt ") {
        await handleEncryptREPLCommand(input, context: context)
    } else if input.hasPrefix("/pref ") {
        await handlePrefREPLCommand(input)
    }
}

@MainActor
private func handlePrefREPLCommand(_ input: String) async {
    let args = input.dropFirst("/pref ".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard let key = parts.first else {
        print("Usage: /pref <chatstates|markers> on|off")
        return
    }
    let valueArg = parts.count == 2 ? String(parts[1]) : nil

    switch String(key) {
    case "chatstates":
        togglePref(name: "Chat states", key: "chatstates", value: valueArg, get: { ChatPreferences.shared.enableChatStates }, set: { ChatPreferences.shared.enableChatStates = $0 })
    case "markers":
        togglePref(name: "Displayed markers", key: "markers", value: valueArg, get: { ChatPreferences.shared.enableDisplayedMarkers }, set: { ChatPreferences.shared.enableDisplayedMarkers = $0 })
    default:
        print("Unknown preference: \(key). Available: chatstates, markers")
    }
}

@MainActor
private func togglePref(name: String, key: String, value: String?, get: () -> Bool, set: (Bool) -> Void) {
    guard let value else {
        let current = get() ? "on" : "off"
        print("\(name): \(current)")
        return
    }
    switch value.lowercased() {
    case "on":
        set(true)
        print("\(name) enabled.")
    case "off":
        set(false)
        print("\(name) disabled.")
    default:
        print("Usage: /pref \(key) on|off")
    }
}

private func handleEncryptREPLCommand(_ input: String, context: REPLContext) async {
    let args = input.dropFirst("/encrypt ".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /encrypt <jid> on|off")
        return
    }
    let jidString = String(parts[0])
    let toggle = String(parts[1]).lowercased()
    guard toggle == "on" || toggle == "off" else {
        print("Usage: /encrypt <jid> on|off")
        return
    }
    let enabled = toggle == "on"
    do {
        let conversation = try await context.environment.chatService.openConversation(
            jidString: jidString, accountID: context.accountID
        )
        try await context.environment.chatService.setEncryptionEnabled(
            enabled, for: conversation.id, accountID: context.accountID
        )
        let state = enabled ? "enabled" : "disabled"
        print("Encryption \(state) for \(jidString).")
    } catch {
        print("Error: \(error)")
    }
}

private func formatFingerprintHex(_ hex: String) -> String {
    OMEMODeviceInfo.formatFingerprint(hex)
}

private func dispatchFileTransferREPLCommand(
    _ input: String, context: REPLContext, currentRoom: String?
) async {
    if input == "/sendfile" || input.hasPrefix("/sendfile ") {
        await handleSendFileREPLCommand(input, context: context, currentRoom: currentRoom)
    } else if input == "/accept" || input.hasPrefix("/accept ") {
        await handleAcceptREPLCommand(input, context: context)
    } else if input == "/decline" || input.hasPrefix("/decline ") {
        await handleDeclineREPLCommand(input, context: context)
    } else if input == "/fulfill" || input.hasPrefix("/fulfill ") {
        await handleFulfillREPLCommand(input, context: context)
    } else if input == "/transfers" {
        await handleTransfersREPLCommand(context: context)
    }
}

private func dispatchRoomREPLCommand(
    _ input: String, context: REPLContext, currentRoom: String?
) async -> REPLDispatchResult {
    let formatter = context.formatter
    let environment = context.environment
    let accountID = context.accountID
    if input == "/join" || input.hasPrefix("/join ") {
        return await handleJoinREPLCommand(input, context: context)
    } else if input == "/leave" || input.hasPrefix("/leave ") {
        return await handleLeaveREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    } else if input == "/members" || input.hasPrefix("/members ") {
        let args = input.dropFirst("/members".count).trimmingCharacters(in: .whitespaces)
        let roomJID = args.isEmpty ? currentRoom : args
        guard let roomJID else {
            print(formatter.formatError(CLIError.noRoomSpecified))
            return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
        }
        await printRoomMembers(jidString: roomJID, environment: environment, formatter: formatter)
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    } else if input == "/topic" || input.hasPrefix("/topic ") {
        return await handleTopicREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    } else if input == "/nick" || input.hasPrefix("/nick ")
        || input == "/destroy" || input.hasPrefix("/destroy ")
        || input == "/voice" || input.hasPrefix("/voice ")
        || input == "/affiliations" || input.hasPrefix("/affiliations ")
        || input == "/config"
        || input == "/moderate" || input.hasPrefix("/moderate ") {
        return await dispatchRoomAdminREPLCommand(input, context: context, currentRoom: currentRoom)
    } else if input == "/rooms" || input.hasPrefix("/rooms ") {
        await handleRoomsREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID)
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    } else if input.hasPrefix("/pm ") {
        return await handlePMREPLCommand(input, context: context, currentRoom: currentRoom)
    } else {
        return REPLDispatchResult(handled: false, updatedCurrentRoom: nil)
    }
}

private func handleJoinREPLCommand(
    _ input: String, context: REPLContext
) async -> REPLDispatchResult {
    let args = input.dropFirst("/join".count).trimmingCharacters(in: .whitespaces)
    guard !args.isEmpty else {
        print("Usage: /join <room-jid> [nickname]")
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    let parts = args.split(separator: " ", maxSplits: 1)
    guard let roomPart = parts.first else {
        print("Usage: /join <room-jid> [nickname]")
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    let roomJID = String(roomPart)
    let nick = parts.count > 1 ? String(parts[1]) : context.accountJID.localPart ?? context.accountJID.description
    do {
        try await context.environment.chatService.joinRoom(jidString: roomJID, nickname: nick, accountID: context.accountID)
        try await waitForRoomJoined(roomJID: roomJID, environment: context.environment)
        let count = await MainActor.run { context.environment.chatService.participantCount(forRoomJIDString: roomJID) }
        print(context.formatter.formatRoomJoinedConfirmation(room: roomJID, nickname: nick, participantCount: count, subject: nil))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: roomJID)
    } catch {
        print(context.formatter.formatError(error))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
}

private func handleLeaveREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    let args = input.dropFirst("/leave".count).trimmingCharacters(in: .whitespaces)
    let roomJID = args.isEmpty ? currentRoom : args
    guard let roomJID else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    do {
        try await environment.chatService.leaveRoom(jidString: roomJID, accountID: accountID)
        print("Left \(roomJID).")
        let cleared: String?? = currentRoom == roomJID ? .some(nil) : nil
        return REPLDispatchResult(handled: true, updatedCurrentRoom: cleared)
    } catch {
        print(formatter.formatError(error))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
}

private func handleTopicREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    let args = input.dropFirst("/topic".count).trimmingCharacters(in: .whitespaces)

    if args.isEmpty {
        // No API to read topic directly; confirm current room
        guard let roomJID = currentRoom else {
            print(formatter.formatError(CLIError.noRoomSpecified))
            return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
        }
        print("Current room: \(roomJID)")
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }

    let parts = args.split(separator: " ", maxSplits: 1)
    // If first part looks like a JID and there are more parts, treat as: /topic <room> <text>
    let roomJID: String
    let subject: String
    if parts.count > 1, BareJID.parse(String(parts[0])) != nil {
        roomJID = String(parts[0])
        subject = String(parts[1])
    } else if let current = currentRoom {
        roomJID = current
        subject = args
    } else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }

    do {
        try await environment.chatService.setRoomSubject(jidString: roomJID, subject: subject, accountID: accountID)
        print("Topic set for \(roomJID).")
    } catch {
        print(formatter.formatError(error))
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func dispatchRoomAdminREPLCommand(
    _ input: String, context: REPLContext, currentRoom: String?
) async -> REPLDispatchResult {
    let formatter = context.formatter
    let environment = context.environment
    let accountID = context.accountID
    if input == "/nick" || input.hasPrefix("/nick ") {
        return await handleNickREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    } else if input == "/destroy" || input.hasPrefix("/destroy ") {
        return await handleDestroyREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    } else if input == "/voice" || input.hasPrefix("/voice ") {
        return await handleVoiceREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    } else if input == "/affiliations" || input.hasPrefix("/affiliations ") {
        return await handleAffiliationsREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    } else if input == "/config" {
        return await handleConfigREPLCommand(formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    } else if input == "/moderate" || input.hasPrefix("/moderate ") {
        return await handleModerateREPLCommand(input, formatter: formatter, environment: environment, accountID: accountID, currentRoom: currentRoom)
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func handleNickREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    let args = input.dropFirst("/nick".count).trimmingCharacters(in: .whitespaces)
    guard !args.isEmpty else {
        print("Usage: /nick <new-nickname>")
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    guard let roomJID = currentRoom else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    do {
        try await environment.chatService.changeRoomNickname(jidString: roomJID, newNickname: args, accountID: accountID)
    } catch {
        print(formatter.formatError(error))
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func handleDestroyREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    guard let roomJID = currentRoom else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    let reason = input.dropFirst("/destroy".count).trimmingCharacters(in: .whitespaces)
    do {
        try await environment.chatService.destroyRoom(
            jidString: roomJID,
            reason: reason.isEmpty ? nil : reason,
            accountID: accountID
        )
        print("Room \(roomJID) destroyed.")
        return REPLDispatchResult(handled: true, updatedCurrentRoom: .some(nil))
    } catch {
        print(formatter.formatError(error))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
}

private func handleVoiceREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    let args = input.dropFirst("/voice".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard parts.count == 2, let action = parts.first, let nickname = parts.last else {
        print("Usage: /voice grant|revoke <nickname>")
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    guard let roomJID = currentRoom else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    do {
        switch String(action) {
        case "grant":
            try await environment.chatService.grantVoice(nickname: String(nickname), inRoomJIDString: roomJID, accountID: accountID)
            print("Granted voice to \(nickname).")
        case "revoke":
            try await environment.chatService.revokeVoice(nickname: String(nickname), inRoomJIDString: roomJID, accountID: accountID)
            print("Revoked voice from \(nickname).")
        default:
            print("Usage: /voice grant|revoke <nickname>")
        }
    } catch {
        print(formatter.formatError(error))
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func handleAffiliationsREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    guard let roomJID = currentRoom else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    let args = input.dropFirst("/affiliations".count).trimmingCharacters(in: .whitespaces)
    let affiliation: RoomAffiliation = switch args {
    case "admin": .admin
    case "owner": .owner
    case "outcast": .outcast
    default: .member
    }
    do {
        let items = try await environment.chatService.getAffiliationList(
            affiliation: affiliation,
            inRoomJIDString: roomJID,
            accountID: accountID
        )
        if items.isEmpty {
            print("No \(affiliation.displayName.lowercased())s.")
        } else {
            print("--- \(affiliation.displayName)s (\(items.count)) ---")
            for item in items {
                var line = "  \(item.jidString)"
                if let nickname = item.nickname {
                    line += " (\(nickname))"
                }
                print(line)
            }
        }
    } catch {
        print(formatter.formatError(error))
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func handleConfigREPLCommand(
    formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    guard let roomJID = currentRoom else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    do {
        let fields = try await environment.chatService.getRoomConfig(jidString: roomJID, accountID: accountID)
        let visible = fields.filter { $0.variable != "FORM_TYPE" && $0.type != "hidden" }
        if visible.isEmpty {
            print("No configuration fields.")
        } else {
            for field in visible {
                let label = field.label ?? field.variable
                let value = field.values.joined(separator: ", ")
                print("  \(label): \(value)")
            }
        }
    } catch {
        print(formatter.formatError(error))
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func handleModerateREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment,
    accountID: UUID, currentRoom: String?
) async -> REPLDispatchResult {
    guard let roomJID = currentRoom else {
        print(formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    let reason = input.dropFirst("/moderate".count).trimmingCharacters(in: .whitespaces)
    guard let bareJID = BareJID.parse(roomJID) else {
        print(formatter.formatError(CLIError.invalidJID(roomJID)))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    do {
        let messages = try await fetchHistory(
            jid: bareJID, before: nil, limit: 20,
            environment: environment, accountID: accountID
        )
        guard let target = messages.last(where: { !$0.isRetracted && !$0.isOutgoing && $0.serverID != nil }),
              let serverID = target.serverID
        else {
            print("No moderatable message found.")
            return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
        }
        try await environment.chatService.moderateMessage(
            serverID: serverID, in: bareJID,
            reason: reason.isEmpty ? nil : reason, accountID: accountID
        )
        print("Moderated message (server-id: \(serverID)).")
    } catch {
        print(formatter.formatError(error))
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func handleRoomsREPLCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID
) async {
    let args = input.dropFirst("/rooms".count).trimmingCharacters(in: .whitespaces)

    let serviceJID: String
    if args.isEmpty {
        guard let discovered = await environment.chatService.discoverMUCService(accountID: accountID) else {
            print(formatter.formatError(CLIError.noMUCService))
            return
        }
        serviceJID = discovered
    } else {
        serviceJID = args
    }

    do {
        let rooms = try await environment.chatService.discoverRooms(on: serviceJID, accountID: accountID)
        printDiscoveredRooms(rooms, formatter: formatter)
    } catch {
        print(formatter.formatError(error))
    }
}

private func handlePMREPLCommand(
    _ input: String, context: REPLContext, currentRoom: String?
) async -> REPLDispatchResult {
    let args = input.dropFirst("/pm ".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /pm <nickname> <message> (must be in a room)")
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    guard let currentRoom else {
        print(context.formatter.formatError(CLIError.noRoomSpecified))
        return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
    }
    let nickname = String(parts[0])
    let body = String(parts[1])
    do {
        try await context.environment.chatService.sendMUCPrivateMessage(
            roomJIDString: currentRoom, nickname: nickname, body: body, accountID: context.accountID
        )
        print("PM to \(nickname) sent.")
    } catch {
        print(context.formatter.formatError(error))
    }
    return REPLDispatchResult(handled: true, updatedCurrentRoom: nil)
}

private func leaveCurrentRoom(_ currentRoom: String?, environment: AppEnvironment, accountID: UUID) async {
    guard let currentRoom else { return }
    try? await environment.chatService.leaveRoom(jidString: currentRoom, accountID: accountID)
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
        let isRoom = await MainActor.run { !(environment.chatService.roomParticipants[jidString]?.isEmpty ?? true) }
        if isRoom {
            try await environment.chatService.sendGroupMessage(to: recipientJID, body: messageBody, accountID: accountID)
        } else {
            try await environment.chatService.sendMessage(to: recipientJID, body: messageBody, accountID: accountID)
        }
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

private func handleAddCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID
) async {
    let args = input.dropFirst("/add ".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard let jidPart = parts.first else {
        print(formatter.formatError(CLIError.invalidJID("usage: /add <jid> [name]")))
        return
    }
    let jidString = String(jidPart)
    guard let bareJID = BareJID.parse(jidString) else {
        print(formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    let name: String? = parts.count > 1 ? String(parts[1]) : nil

    do {
        try await environment.rosterService.addContact(jid: bareJID, name: name, groups: [], accountID: accountID)
        print("Added \(jidString) to roster.")
    } catch {
        print(formatter.formatError(error))
    }
}

private func handleHistoryCommand(
    _ input: String, formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID, accountJID: BareJID
) async {
    let args = input.dropFirst("/history".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)

    guard let jidPart = parts.first else {
        print(formatter.formatError(CLIError.invalidJID("usage: /history <jid> [limit]")))
        return
    }

    let jidString = String(jidPart)
    guard let bareJID = BareJID.parse(jidString) else {
        print(formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }

    var limit = 20
    if parts.count > 1 {
        guard let parsed = Int(parts[1]), parsed > 0 else {
            print(formatter.formatError(CLIError.invalidJID("usage: /history <jid> [limit]")))
            return
        }
        limit = parsed
    }

    do {
        let messages = try await fetchHistory(
            jid: bareJID, before: nil, limit: limit,
            environment: environment, accountID: accountID
        )
        printHistory(messages, formatter: formatter, accountJID: accountJID)
    } catch {
        print(formatter.formatError(error))
    }
}

private func handleAvatarREPLCommand(_ input: String, context: REPLContext) async {
    let args = input.dropFirst("/avatar".count).trimmingCharacters(in: .whitespaces)

    if args.isEmpty {
        // Show own avatar info
        let hash = await MainActor.run { context.environment.avatarService.ownAvatarHash }
        if let hash {
            print("Own avatar hash: \(hash)")
        } else {
            print("No avatar set.")
        }
        return
    }

    guard let jid = BareJID.parse(args) else {
        print("Invalid JID: \(args)")
        return
    }

    guard let avatar = await context.environment.avatarService.fetchAvatar(for: jid, accountID: context.accountID) else {
        print("No avatar found for \(jid).")
        return
    }

    print("Avatar for \(jid):")
    print("  Hash: \(avatar.hash)")
    print("  Type: \(avatar.mimeType)")
    print("  Size: \(avatar.data.count) bytes")
}

private func handleProfileREPLCommand(context: REPLContext) async {
    let output = await fetchAndFormatProfile(
        environment: context.environment, accountID: context.accountID, formatter: context.formatter
    )
    print(output)
}

private func fetchAndFormatProfile(
    environment: AppEnvironment, accountID: UUID, formatter: any CLIFormatter
) async -> String {
    await environment.profileService.fetchOwnProfile(accountID: accountID)
    let profile = await MainActor.run { environment.profileService.ownProfile }
    if let profile {
        return formatter.formatProfile(profile)
    }
    return formatter.formatProfile(ProfileInfo())
}

private func handleConnectionInfoREPLCommand(context: REPLContext) async {
    let info = await MainActor.run { context.environment.accountService.tlsInfo(for: context.accountID) }
    if let info {
        print(context.formatter.formatTLSInfo(info))
    } else {
        print("No TLS connection info available.")
    }
}

private func handleRetractREPLCommand(_ input: String, context: REPLContext) async {
    let jidString = input.dropFirst("/retract ".count).trimmingCharacters(in: .whitespaces)
    guard !jidString.isEmpty else {
        print("Usage: /retract <jid>")
        return
    }
    guard let bareJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        let messages = try await fetchHistory(
            jid: bareJID, before: nil, limit: 10,
            environment: context.environment, accountID: context.accountID
        )
        guard let lastOutgoing = messages.last(where: { $0.isOutgoing && $0.stanzaID != nil && !$0.isRetracted }),
              let stanzaID = lastOutgoing.stanzaID
        else {
            print("No recent outgoing message to retract.")
            return
        }
        let isGroupchat = lastOutgoing.type == "groupchat"
        if isGroupchat {
            try await context.environment.chatService.retractGroupMessage(
                stanzaID: stanzaID, inRoomJIDString: jidString,
                accountID: context.accountID
            )
        } else {
            try await context.environment.chatService.retractMessage(
                stanzaID: stanzaID, toJIDString: jidString,
                accountID: context.accountID
            )
        }
        print("Retracted message: \(stanzaID)")
    } catch {
        print(context.formatter.formatError(error))
    }
}

private func handleEditREPLCommand(_ input: String, context: REPLContext) async {
    let args = input.dropFirst("/edit ".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /edit <jid> <new-body>")
        return
    }
    let jidString = String(parts[0])
    let newBody = String(parts[1])
    guard let bareJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        let messages = try await fetchHistory(
            jid: bareJID, before: nil, limit: 10,
            environment: context.environment, accountID: context.accountID
        )
        guard let lastOutgoing = messages.last(where: { $0.isOutgoing && $0.stanzaID != nil && !$0.isRetracted }),
              let stanzaID = lastOutgoing.stanzaID
        else {
            print("No recent outgoing message to edit.")
            return
        }
        let isGroupchat = lastOutgoing.type == "groupchat"
        if isGroupchat {
            try await context.environment.chatService.sendGroupCorrection(
                originalStanzaID: stanzaID, newBody: newBody,
                inRoomJIDString: jidString, accountID: context.accountID
            )
        } else {
            try await context.environment.chatService.sendCorrection(
                toJIDString: jidString, originalStanzaID: stanzaID,
                newBody: newBody, accountID: context.accountID
            )
        }
        print("Edited message: \(stanzaID)")
    } catch {
        print(context.formatter.formatError(error))
    }
}

private func handleReplyREPLCommand(_ input: String, context: REPLContext) async {
    let args = input.dropFirst("/reply ".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /reply <jid> <message>")
        return
    }
    let jidString = String(parts[0])
    let body = String(parts[1])
    guard let bareJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        let messages = try await fetchHistory(
            jid: bareJID, before: nil, limit: 10,
            environment: context.environment, accountID: context.accountID
        )
        guard let lastIncoming = messages.last(where: { !$0.isOutgoing && $0.stanzaID != nil }),
              let replyStanzaID = lastIncoming.stanzaID
        else {
            print("No recent incoming message to reply to.")
            return
        }
        try await context.environment.chatService.sendReply(
            toJIDString: jidString, body: body,
            replyToStanzaID: replyStanzaID,
            accountID: context.accountID
        )
        print(context.formatter.formatMessage(ChatMessage.displayPlaceholder(
            fromJID: jidString, body: body, replyToID: replyStanzaID
        ), accountJID: context.accountJID))
    } catch {
        print(context.formatter.formatError(error))
    }
}

private func handleSearchREPLCommand(_ input: String, context: REPLContext) async {
    let args = input.dropFirst("/search ".count).trimmingCharacters(in: .whitespaces)
    let parts = args.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /search <jid> <query>")
        return
    }
    let jidString = String(parts[0])
    let query = String(parts[1])
    guard let bareJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        let messages = try await searchHistory(
            jid: bareJID, query: query, limit: 20,
            environment: context.environment, accountID: context.accountID
        )
        printHistory(messages, formatter: context.formatter, accountJID: context.accountJID)
    } catch {
        print(context.formatter.formatError(error))
    }
}

private func handleJIDCommand(
    _ input: String, prefix: String, successMessage: String,
    formatter: any CLIFormatter, action: (String) async throws -> Void
) async {
    let jidString = input.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    guard BareJID.parse(jidString) != nil else {
        print(formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        try await action(jidString)
        print(successMessage.replacingOccurrences(of: "{jid}", with: jidString))
    } catch {
        print(formatter.formatError(error))
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
