import Foundation

/// A fully parsed Adium chat log file with its entries and source path for stanzaID generation.
package struct AdiumLogFile {
    let entries: [AdiumLogEntry]
    let sourcePath: String
}
