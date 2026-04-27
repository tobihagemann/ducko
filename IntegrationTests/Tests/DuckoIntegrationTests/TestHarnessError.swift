import Foundation

/// Errors thrown by `TestHarness` and `ConnectedAccount` helpers.
enum TestHarnessError: Error, CustomStringConvertible {
    case timeout
    case streamClosed
    case notConnected(label: String)
    case moduleUnavailable(label: String, type: String)
    case binaryMissing(path: String)
    case nonZeroExit(code: Int32, stdout: String, stderr: String)
    case appBundleMissing(path: String)
    case appBundleNotDebug(path: String)
    case axTrustMissing
    case elementNotFound(identifier: String)

    var description: String {
        switch self {
        case .timeout: "TestHarnessError.timeout"
        case .streamClosed: "TestHarnessError.streamClosed"
        case let .notConnected(label): "TestHarnessError.notConnected(\(label))"
        case let .moduleUnavailable(label, type): "TestHarnessError.moduleUnavailable(\(label), \(type))"
        case let .binaryMissing(path): "TestHarnessError.binaryMissing(\(path))"
        case let .nonZeroExit(code, stdout, stderr):
            // CLI stdout/stderr routinely include JIDs (e.g. `ducko send <jid>` echoes,
            // `account list` output). Swift Testing prints `description` when an `Issue`
            // surfaces a thrown error, so the project privacy policy applies — redact
            // before printing.
            "TestHarnessError.nonZeroExit(code: \(code), stdout: \(Self.redactJIDs(in: stdout)), stderr: \(Self.redactJIDs(in: stderr)))"
        case let .appBundleMissing(path): "TestHarnessError.appBundleMissing(\(path))"
        case let .appBundleNotDebug(path): "TestHarnessError.appBundleNotDebug(\(path))"
        case .axTrustMissing: "TestHarnessError.axTrustMissing"
        case let .elementNotFound(identifier):
            "TestHarnessError.elementNotFound(\(Self.redactJIDs(in: identifier)))"
        }
    }

    /// Replaces tokens containing `@` with `<jid>`. Tokenization splits on
    /// `-` (the kebab-identifier separator used throughout `Sources/DuckoUI`)
    /// and on whitespace + common punctuation (the typical separators in
    /// CLI stdout/stderr). The kebab prefix of an identifier such as
    /// `contact-row-bob@example.com` is preserved (`contact-row-<jid>`)
    /// because the JID is its own kebab token.
    ///
    /// Limitation: hyphens are ambiguous — RFC 7622 allows them inside
    /// localparts and IDNA inside domains. A hyphenated localpart like
    /// `qa-user@example.org` would tokenize to `[qa, user@example.org]`,
    /// leaking `qa-` into the prefix. The test JIDs in this repo
    /// (alice/bob/carol/dave) never use hyphens, so the simple tokenizer
    /// is sufficient. If a hyphenated test account is ever added, switch
    /// to a JID-aware grammar match here.
    static func redactJIDs(in input: String) -> String {
        let separators: Set<Character> = ["-", " ", "\t", "\n", ",", ";", ":"]
        var result = ""
        var token = ""
        for character in input {
            if separators.contains(character) {
                result.append(token.contains("@") ? "<jid>" : token)
                result.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        result.append(token.contains("@") ? "<jid>" : token)
        return result
    }
}
