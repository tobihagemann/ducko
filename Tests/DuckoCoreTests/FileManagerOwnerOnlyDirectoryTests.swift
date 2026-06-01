import DuckoCore
import DuckoTestSupport
import Foundation
import Testing

/// Locks the 0700 owner-only + create-or-repair contract of `FileManager.createOwnerOnlyDirectory(at:)`.
struct FileManagerOwnerOnlyDirectoryTests {
    @Test func `a fresh directory is created mode 0700`() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("keys", isDirectory: true)
            try FileManager.default.createOwnerOnlyDirectory(at: url)
            #expect(try posixMode(of: url) == 0o700)
        }
    }

    @Test func `a missing intermediate is created at 0700`() throws {
        try withTemporaryDirectory { dir in
            let intermediate = dir.appendingPathComponent("parent", isDirectory: true)
            let url = intermediate.appendingPathComponent("child", isDirectory: true)
            try FileManager.default.createOwnerOnlyDirectory(at: url)
            #expect(try posixMode(of: url) == 0o700)
            #expect(try posixMode(of: intermediate) == 0o700)
        }
    }

    @Test func `a pre-existing 0755 directory is repaired to 0700`() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            #expect(try posixMode(of: url) == 0o755)
            try FileManager.default.createOwnerOnlyDirectory(at: url)
            #expect(try posixMode(of: url) == 0o700)
        }
    }

    @Test func `a pre-existing weak intermediate is left untouched while the leaf becomes 0700`() throws {
        try withTemporaryDirectory { dir in
            let intermediate = dir.appendingPathComponent("parent", isDirectory: true)
            try FileManager.default.createDirectory(at: intermediate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let url = intermediate.appendingPathComponent("child", isDirectory: true)
            try FileManager.default.createOwnerOnlyDirectory(at: url)
            #expect(try posixMode(of: url) == 0o700)
            #expect(try posixMode(of: intermediate) == 0o755)
        }
    }

    @Test func `calling twice is idempotent and stays 0700`() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("keys", isDirectory: true)
            try FileManager.default.createOwnerOnlyDirectory(at: url)
            try FileManager.default.createOwnerOnlyDirectory(at: url)
            #expect(try posixMode(of: url) == 0o700)
        }
    }

    @Test func `a path occupied by a file throws`() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("occupied")
            try Data("payload".utf8).write(to: url)
            #expect(throws: CocoaError.self) {
                try FileManager.default.createOwnerOnlyDirectory(at: url)
            }
        }
    }

    @Test func `a symlink at the leaf is rejected without repairing its target`() throws {
        try withTemporaryDirectory { dir in
            let target = dir.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            let link = dir.appendingPathComponent("leaf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let error = #expect(throws: CocoaError.self) {
                try FileManager.default.createOwnerOnlyDirectory(at: link)
            }
            #expect(error?.code == .fileWriteUnknown)
            #expect(error?.userInfo[NSFilePathErrorKey] as? String == link.path)
            #expect(try posixMode(of: target) == 0o755)
        }
    }
}
