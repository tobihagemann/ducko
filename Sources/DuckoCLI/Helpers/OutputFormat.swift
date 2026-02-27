import ArgumentParser

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case plain
    case ansi
    case json

    static var defaultForTerminal: OutputFormat {
        isatty(STDOUT_FILENO) != 0 ? .ansi : .plain
    }

    func makeFormatter() -> any CLIFormatter {
        switch self {
        case .plain: PlainFormatter()
        case .ansi: ANSIFormatter()
        case .json: JSONFormatter()
        }
    }
}
