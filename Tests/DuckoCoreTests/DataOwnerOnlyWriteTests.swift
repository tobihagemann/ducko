import DuckoCore
import Foundation
import Testing

/// Locks the 0600 owner-only + atomic-overwrite contract of `Data.writeOwnerOnly(to:)`.
struct DataOwnerOnlyWriteTests {
    private static func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ducko-owneronly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private static func posixMode(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func `written file is mode 0600`() throws {
        try Self.withTempDir { dir in
            let url = dir.appendingPathComponent("creds.json")
            try Data("payload".utf8).writeOwnerOnly(to: url)
            #expect(try Self.posixMode(of: url) == 0o600)
        }
    }

    @Test func `written file content round-trips`() throws {
        try Self.withTempDir { dir in
            let url = dir.appendingPathComponent("creds.json")
            let payload = Data("the-secret-bytes".utf8)
            try payload.writeOwnerOnly(to: url)
            #expect(try Data(contentsOf: url) == payload)
        }
    }

    @Test func `overwriting an existing file replaces content and stays 0600`() throws {
        try Self.withTempDir { dir in
            let url = dir.appendingPathComponent("creds.json")
            try Data("first".utf8).writeOwnerOnly(to: url)
            try Data("second".utf8).writeOwnerOnly(to: url)
            #expect(try Data(contentsOf: url) == Data("second".utf8))
            #expect(try Self.posixMode(of: url) == 0o600)
        }
    }

    @Test func `no temp file remains after a successful write`() throws {
        try Self.withTempDir { dir in
            let url = dir.appendingPathComponent("creds.json")
            try Data("payload".utf8).writeOwnerOnly(to: url)
            let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(entries == ["creds.json"])
        }
    }

    @Test func `write into a missing directory throws a file-write error`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ducko-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("creds.json")
        let error = #expect(throws: CocoaError.self) {
            try Data("payload".utf8).writeOwnerOnly(to: url)
        }
        #expect(error?.code == .fileWriteUnknown)
        #expect(error?.userInfo[NSFilePathErrorKey] as? String == url.path)
    }

    @Test func `rename failure removes the temp file and throws`() throws {
        try Self.withTempDir { dir in
            // A path that already exists as a directory makes the final rename fail
            // (file → directory), exercising the post-temp-creation cleanup branch.
            let url = dir.appendingPathComponent("occupied", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(throws: CocoaError.self) {
                try Data("payload".utf8).writeOwnerOnly(to: url)
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.contains(".tmp.") }
            #expect(leftovers.isEmpty)
        }
    }
}
