import Testing

/// Ungated unit tests for CLI-adjacent test helpers (`OutputBuffer`,
/// `bindLoopbackTCPSocket`). Unlike `DuckoIntegrationTests.CLILayer`, these need
/// neither live XMPP credentials nor the built `ducko` binary, so they run in
/// credentialless CI instead of being skipped by the integration-suite gates.
@Suite("CLI Helper Unit Tests")
enum CLIHelperUnitTests {}
