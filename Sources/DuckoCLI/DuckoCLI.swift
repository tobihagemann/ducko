import ArgumentParser

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

// MARK: - Subcommands

extension DuckoCLI {
    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send a message to a JID"
        )

        @Argument(help: "The recipient JID")
        var jid: String

        @Argument(help: "The message body")
        var body: String

        func run() async throws {
            print("send: not yet implemented")
        }
    }

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

            func run() async throws {
                print("roster list: not yet implemented")
            }
        }
    }

    struct Presence: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Get or set presence status"
        )

        func run() async throws {
            print("presence: not yet implemented")
        }
    }

    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "View message history"
        )

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

            func run() async throws {
                print("room list: not yet implemented")
            }
        }
    }

    struct Account: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage XMPP accounts",
            subcommands: [List.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List configured accounts"
            )

            func run() async throws {
                print("account list: not yet implemented")
            }
        }
    }

    struct Interactive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start interactive REPL mode"
        )

        func run() async throws {
            print("interactive: not yet implemented")
        }
    }
}
