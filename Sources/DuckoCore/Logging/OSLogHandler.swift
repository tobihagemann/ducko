import Logging
import os

private typealias OSLogger = os.Logger

/// A swift-log `LogHandler` that forwards messages to Apple's unified logging system via `os.Logger`.
///
/// Parses the logger label to derive an OSLog subsystem and category:
/// `"im.ducko.xmpp.client"` → subsystem `"im.ducko.xmpp"`, category `"client"`.
struct OSLogHandler: LogHandler {
    private let osLogger: OSLogger

    var logLevel: Logging.Logger.Level = .trace
    var metadata: Logging.Logger.Metadata = [:]

    init(label: String) {
        let (subsystem, category) = Self.parseLabel(label)
        self.osLogger = OSLogger(subsystem: subsystem, category: category)
    }

    // swiftlint:disable:next function_parameter_count
    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let msg = message.description
        switch level {
        case .trace, .debug:
            osLogger.debug("\(msg, privacy: .public)")
        case .info:
            osLogger.info("\(msg, privacy: .public)")
        case .notice:
            osLogger.notice("\(msg, privacy: .public)")
        case .warning:
            osLogger.warning("\(msg, privacy: .public)")
        case .error:
            osLogger.error("\(msg, privacy: .public)")
        case .critical:
            osLogger.fault("\(msg, privacy: .public)")
        }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    // MARK: - Label Parsing

    /// Splits `"im.ducko.xmpp.client"` into `("im.ducko.xmpp", "client")`.
    /// Falls back to the full label for both subsystem and category if no dot is found.
    static func parseLabel(_ label: String) -> (subsystem: String, category: String) {
        guard let lastDot = label.lastIndex(of: ".") else {
            return (label, label)
        }
        let subsystem = String(label[label.startIndex ..< lastDot])
        let category = String(label[label.index(after: lastDot)...])
        return (subsystem, category)
    }
}
