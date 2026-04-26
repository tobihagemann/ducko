/// Errors thrown by `TestHarness` and `ConnectedAccount` helpers.
enum TestHarnessError: Error, CustomStringConvertible {
    case timeout
    case streamClosed
    case notConnected(label: String)
    case moduleUnavailable(label: String, type: String)
    case binaryMissing(path: String)
    case nonZeroExit(code: Int32, stdout: String, stderr: String)

    var description: String {
        switch self {
        case .timeout: "TestHarnessError.timeout"
        case .streamClosed: "TestHarnessError.streamClosed"
        case let .notConnected(label): "TestHarnessError.notConnected(\(label))"
        case let .moduleUnavailable(label, type): "TestHarnessError.moduleUnavailable(\(label), \(type))"
        case let .binaryMissing(path): "TestHarnessError.binaryMissing(\(path))"
        case let .nonZeroExit(code, stdout, stderr):
            "TestHarnessError.nonZeroExit(code: \(code), stdout: \(stdout), stderr: \(stderr))"
        }
    }
}
