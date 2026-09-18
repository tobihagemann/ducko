import ArgumentParser
import DuckoCore
import Foundation

extension DuckoCLI {
    struct Profile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "View own vCard profile"
        )

        @OptionGroup var global: GlobalOptions

        @OptionGroup var accountOption: AccountOption

        func run() async throws {
            let formatter = global.formatter

            try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                let output = await fetchAndFormatProfile(
                    environment: env, accountID: selectedAccount.id, formatter: formatter
                )
                print(output)
            }
        }
    }
}
