import ArgumentParser
import DuckoCore

extension DuckoCLI {
    struct ServerInfoCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "server-info",
            abstract: "Show server contact information (XEP-0157)"
        )

        @OptionGroup var global: GlobalOptions

        @OptionGroup var accountOption: AccountOption

        func run() async throws {
            let formatter = global.formatter

            try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                let info = try await env.accountService.fetchServerInfo(accountID: selectedAccount.id)
                print(formatter.formatServerInfo(info))
            }
        }
    }
}
