import Foundation
import Testing

/// Runs `body` against a unique temporary directory, removed afterward.
public func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ducko-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

public func posixMode(of url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
    try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int,
        sourceLocation: sourceLocation
    )
}
