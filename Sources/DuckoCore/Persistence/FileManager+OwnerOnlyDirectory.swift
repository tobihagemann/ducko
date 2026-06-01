import Foundation

public extension FileManager {
    /// Creates the directory at `url` (and any missing intermediates) owner-only
    /// (0700) so it never sits group/other-readable. Because
    /// `createDirectory(attributes:)` is a no-op when the directory already
    /// exists, a second `setAttributes` repair step re-applies 0700 to a directory
    /// that already exists at a weaker mode (e.g. the umask default 0755). The
    /// repair touches only the leaf target, so a pre-existing intermediate at a
    /// weaker mode is not repaired. If the leaf is a symbolic link, the call throws
    /// instead of following it — `setAttributes` would otherwise chmod the link's
    /// target, outside the intended path.
    func createOwnerOnlyDirectory(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try attributesOfItem(atPath: url.path)[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        try setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
