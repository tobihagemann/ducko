/// Errors thrown by `TestHarness` and `ConnectedAccount` helpers.
enum TestHarnessError: Error, CustomStringConvertible {
    case timeout
    case streamClosed
    case notConnected(label: String)
    case moduleUnavailable(label: String, type: String)

    var description: String {
        switch self {
        case .timeout: "TestHarnessError.timeout"
        case .streamClosed: "TestHarnessError.streamClosed"
        case let .notConnected(label): "TestHarnessError.notConnected(\(label))"
        case let .moduleUnavailable(label, type): "TestHarnessError.moduleUnavailable(\(label), \(type))"
        }
    }
}
