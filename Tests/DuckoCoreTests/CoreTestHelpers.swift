import DuckoCore
import DuckoTestSupport
import Foundation

// Helpers shared across every DuckoCoreTests file that drives a real
// `AccountService.createAndConnect(...)` against `MockTransport`. Per-suite
// fixtures (`testAccountID`, `contactJID`, `makeStore`, `makeTranscripts`,
// `makeChatService`, `makeCredentials`) stay file-private to keep individual
// suites uncoupled — only the connect-driving subset is shared here.
//
// `extractIQID` lives in `DuckoTestSupport/HandshakeFixtures.swift` (shared with DuckoXMPPTests).

/// Bound JID used by `MockTransport.testBindResult` — the "alice@example.com"
/// account fixture for tests that exercise an `AccountService` with a mock
/// transport. Hoisted so every test target file that drives a connect uses the
/// same string.
let testJIDString = "alice@example.com"

/// Builds an `AccountService` wired against the in-memory test infrastructure.
/// All parameters default so individual tests only override what they need.
@MainActor
func makeAccountService(
    store: MockPersistenceStore,
    credentials: MockCredentialStore = MockCredentialStore(),
    clientFactory: any XMPPClientFactory = DefaultXMPPClientFactory()
) -> AccountService {
    AccountService(store: store, credentialStore: credentials, clientFactory: clientFactory)
}

/// Extracts the `queryid="..."` attribute value from a raw MAM query IQ.
func extractQueryID(from xmlString: String) -> String? {
    guard let range = xmlString.range(of: "queryid=\""),
          let endRange = xmlString[range.upperBound...].firstIndex(of: "\"") else {
        return nil
    }
    return String(xmlString[range.upperBound ..< endRange])
}
