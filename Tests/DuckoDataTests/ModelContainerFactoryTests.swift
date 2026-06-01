import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoData

/// Locks owner-only store-directory creation for the on-disk `makeContainer` path.
struct ModelContainerFactoryTests {
    @Test func `on-disk container creates the store directory mode 0700`() throws {
        try withTemporaryDirectory { dir in
            let storeDir = dir.appendingPathComponent("Store", isDirectory: true)
            _ = try ModelContainerFactory.makeContainer(at: storeDir)
            #expect(try posixMode(of: storeDir) == 0o700)
            #expect(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("default.store").path))
        }
    }

    @Test func `on-disk container repairs a pre-existing 0755 store directory to 0700`() throws {
        try withTemporaryDirectory { dir in
            let storeDir = dir.appendingPathComponent("Store", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            _ = try ModelContainerFactory.makeContainer(at: storeDir)
            #expect(try posixMode(of: storeDir) == 0o700)
        }
    }
}
