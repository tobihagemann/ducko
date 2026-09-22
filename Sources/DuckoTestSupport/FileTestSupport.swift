import Foundation
import Testing

/// Runs `body` against a unique temporary directory, removed afterward.
public func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// Runs `body` against a unique temporary directory, removed afterward.
public nonisolated(nonsending) func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

private func makeTemporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ducko-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

public func posixMode(of url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
    try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int,
        sourceLocation: sourceLocation
    )
}
