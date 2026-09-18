import ArgumentParser
import DuckoCore

@MainActor
enum RosterCommandOutput {
    static func run(
        formatter: any CLIFormatter,
        output: (String) -> Void = { print($0) },
        operation: () async throws -> RosterCommandOutcome
    ) async throws {
        let outcome: RosterCommandOutcome
        do {
            outcome = try await operation()
        } catch let error as RosterCommandError {
            output(formatter.formatError(error))
            throw ExitCode.failure
        }
        output(formatter.formatRosterCommand(outcome))
        if !outcome.isComplete { throw ExitCode(3) }
    }
}
