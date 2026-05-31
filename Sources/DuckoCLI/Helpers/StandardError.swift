import Foundation

/// Writes a newline-terminated UTF-8 message to standard error. The session-scoped one-shot warning and the
/// informational hold/interrupt lines go here so stdout stays reserved for formatted command and event output.
func printToStandardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
