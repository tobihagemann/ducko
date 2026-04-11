import Foundation

/// Centralized timeout values for live-server integration tests.
///
/// Constants are tuned for a real XMPP server in steady state. Increase only
/// when a slow path is justified — flaky tests should fix the underlying race,
/// not pad the timeout.
enum TestTimeout {
    /// Account connection to a live server (DNS, TCP, TLS, SASL, bind, roster).
    static let connect: Duration = .seconds(15)

    /// Single XMPP event wait (e.g., message delivery, room join).
    static let event: Duration = .seconds(10)

    // periphery:ignore - reserved for file transfer tests
    /// Jingle file transfer end-to-end completion.
    static let fileTransfer: Duration = .seconds(30)

    // periphery:ignore - reserved for OMEMO tests
    /// OMEMO session establishment (device list fetch + bundle fetch + key exchange).
    static let omemoSession: Duration = .seconds(20)

    // periphery:ignore - reserved for UI integration tests
    /// UI element appearance via accessibility queries.
    static let uiElement: Duration = .seconds(10)

    // periphery:ignore - reserved for CLI integration tests
    /// CLI command completion (one-shot subcommand).
    static let cliCommand: Duration = .seconds(15)

    // periphery:ignore - reserved for REPL session tests
    /// REPL output wait after issuing a command.
    static let replOutput: Duration = .seconds(10)
}
