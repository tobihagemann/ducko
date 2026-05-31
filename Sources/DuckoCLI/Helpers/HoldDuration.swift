import Foundation

/// Upper bound for a bounded `--for` hold. Longer holds should use `--keep-alive`.
private let maxHoldSeconds: Int64 = 24 * 60 * 60

/// Parses a single-unit hold duration like `30s`, `15m`, or `2h` into a `Duration`.
///
/// Accepts exactly `<positive-integer><unit>` where unit ∈ `s`/`m`/`h`. Rejects empty input, a missing
/// suffix, bare numbers, compound forms (`1h30m`), internal whitespace, leading `+`/`-`, non-positive
/// values, second-counts that overflow, and anything above the `24h` cap.
func parseHoldDuration(_ token: String) throws -> Duration {
    guard let unit = token.last, let secondsPerUnit = secondsPerHoldUnit(unit) else {
        throw CLIError.invalidDuration(token)
    }
    let digits = token.dropLast()
    guard digits.allSatisfy({ $0.isASCII && $0.isNumber }),
          let value = Int64(digits), value > 0
    else {
        throw CLIError.invalidDuration(token)
    }
    let (seconds, overflowed) = value.multipliedReportingOverflow(by: secondsPerUnit)
    guard !overflowed else {
        throw CLIError.invalidDuration(token)
    }
    guard seconds <= maxHoldSeconds else {
        throw CLIError.durationTooLong(token)
    }
    return .seconds(seconds)
}

private func secondsPerHoldUnit(_ unit: Character) -> Int64? {
    switch unit {
    case "s": 1
    case "m": 60
    case "h": 3600
    default: nil
    }
}
