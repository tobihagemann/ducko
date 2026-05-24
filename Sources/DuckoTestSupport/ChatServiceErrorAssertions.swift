import DuckoCore
import Foundation
import Testing

/// `ChatServiceError` isn't `Equatable`, so `#expect(throws: .notOutgoingMessage)`
/// doesn't compile — pattern-match instead.
@MainActor
public func expectNotOutgoingMessage(
    _ operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected ChatServiceError.notOutgoingMessage but no error was thrown", sourceLocation: sourceLocation)
    } catch ChatService.ChatServiceError.notOutgoingMessage {
        // expected
    } catch {
        Issue.record("Expected ChatServiceError.notOutgoingMessage, got \(error)", sourceLocation: sourceLocation)
    }
}
