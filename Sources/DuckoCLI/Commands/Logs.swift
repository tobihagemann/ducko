import ArgumentParser
import DuckoCore
import Foundation

extension DuckoCLI {
    struct Logs: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "View or export log files",
            subcommands: [Show.self, Export.self, Path.self],
            defaultSubcommand: Show.self
        )

        struct Show: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print recent log entries"
            )

            @Option(name: .shortAndLong, help: "Number of lines to show (default: 50)")
            var lines: Int = 50

            func run() throws {
                let output = try LogExporter.recentLines(count: lines)
                print(output)
            }
        }

        struct Export: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Export all log files to a directory"
            )

            @Argument(help: "Destination directory path")
            var destination: String

            func run() throws {
                let destURL = URL(fileURLWithPath: destination)
                let copied = try LogExporter.export(to: destURL)
                print("Exported \(copied.count) log file(s) to \(destURL.path)")
            }
        }

        struct Path: ParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Print the log directory path"
            )

            func run() {
                print(LoggingConfiguration.logsDirectory.path)
            }
        }
    }
}
