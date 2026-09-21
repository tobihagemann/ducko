import ArgumentParser
import DuckoCore
import DuckoXMPP

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

            @OptionGroup var accountOption: AccountOption

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let contacts = try await env.rosterService.synchronizeRoster(accountID: selectedAccount.id)
                    guard !contacts.isEmpty else {
                        print(formatter.formatEmptyResult(.roster(accountID: selectedAccount.id)))
                        return
                    }
                    let groups = ContactGroup.grouping(contacts)
                    let presences = await MainActor.run {
                        Dictionary(uniqueKeysWithValues: contacts.compactMap { contact in
                            env.presenceService.presence(for: contact.jid, accountID: selectedAccount.id).map { (contact.jid, $0) }
                        })
                    }

                    printRoster(groups: groups, presences: presences, formatter: formatter)
                }
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a contact to the roster"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The JID to add")
            var jid: String

            @Option(name: .long, help: "Display name for the contact")
            var name: String?

            @Option(name: .long, help: "Group for the contact")
            var group: String?

            func run() async throws {
                let formatter = global.formatter

                guard let bareJID = BareJID.parse(jid) else {
                    throw CLIError.invalidJID(jid)
                }

                try await RosterCommandOutput.run(formatter: formatter) {
                    try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                        let groups = group.map { [$0] } ?? []
                        return try await env.rosterService.addContact(jid: bareJID, name: name, groups: groups, accountID: selectedAccount.id)
                    }
                }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove a contact from the roster"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The JID to remove")
            var jid: String

            func run() async throws {
                let formatter = global.formatter

                guard let bareJID = BareJID.parse(jid) else {
                    throw CLIError.invalidJID(jid)
                }

                try await RosterCommandOutput.run(formatter: formatter) {
                    try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                        try await env.rosterService.removeContact(jidString: bareJID.description, accountID: selectedAccount.id)
                    }
                }
            }
        }
    }
}
