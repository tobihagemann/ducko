import Foundation

/// A MUC occupant nickname and the optional argument that follows it, parsed from a
/// REPL command argument.
struct ParsedNicknameArgument {
    /// The occupant nickname; always non-empty.
    let nickname: String
    /// The trimmed remainder after the nickname, or `nil` when absent or whitespace-only.
    let trailingArgument: String?
}

/// Parses a REPL command argument into a nickname and the optional argument that
/// follows it, supporting optional double-quoting so nicknames may contain whitespace.
///
/// Unquoted input takes the first space-delimited token as the nickname and the trimmed
/// remainder as the trailing argument. A leading `"` begins a quoted nickname that may
/// contain spaces; inside the quotes only `\"` and `\\` are recognized escapes, and the
/// closing quote must be followed by end-of-input or whitespace.
///
/// - Parameter arguments: The argument text following the command keyword.
/// - Throws: ``CLIError/malformedQuotedArgument(_:)`` when the input is empty, when a quoted
///   nickname is unterminated, empty, or contains an unsupported or dangling backslash escape,
///   or when characters other than whitespace follow the closing quote.
func parseNicknameArgument(_ arguments: String) throws -> ParsedNicknameArgument {
    let characters = Array(arguments)
    var index = characters.startIndex
    while index < characters.endIndex, characters[index].isWhitespace {
        index += 1
    }
    guard index < characters.endIndex else {
        throw CLIError.malformedQuotedArgument("expected a nickname")
    }
    if characters[index] == "\"" {
        return try parseQuotedNicknameArgument(characters, afterOpeningQuote: index + 1)
    }
    let remainder = String(characters[index...])
    let parts = remainder.split(separator: " ", maxSplits: 1)
    let trailing = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
    return ParsedNicknameArgument(nickname: String(parts[0]), trailingArgument: trailing.isEmpty ? nil : trailing)
}

private func parseQuotedNicknameArgument(_ characters: [Character], afterOpeningQuote start: Int) throws -> ParsedNicknameArgument {
    var index = start
    var nickname = ""
    while index < characters.endIndex {
        switch characters[index] {
        case "\\":
            let escape = index + 1
            guard escape < characters.endIndex else {
                throw CLIError.malformedQuotedArgument("a quoted nickname ends with a dangling backslash")
            }
            let escaped = characters[escape]
            guard escaped == "\"" || escaped == "\\" else {
                throw CLIError.malformedQuotedArgument("unsupported escape \"\\\(escaped)\" in a quoted nickname")
            }
            nickname.append(escaped)
            index += 2
        case "\"":
            return try finishQuotedNicknameArgument(nickname, characters: characters, afterClosingQuote: index + 1)
        default:
            nickname.append(characters[index])
            index += 1
        }
    }
    throw CLIError.malformedQuotedArgument("a quoted nickname is missing its closing quote")
}

private func finishQuotedNicknameArgument(_ nickname: String, characters: [Character], afterClosingQuote index: Int) throws -> ParsedNicknameArgument {
    guard !nickname.isEmpty else {
        throw CLIError.malformedQuotedArgument("a quoted nickname is empty")
    }
    if index < characters.endIndex, !characters[index].isWhitespace {
        throw CLIError.malformedQuotedArgument("unexpected text after the closing quote")
    }
    let remainder = String(characters[index...]).trimmingCharacters(in: .whitespaces)
    return ParsedNicknameArgument(nickname: nickname, trailingArgument: remainder.isEmpty ? nil : remainder)
}
