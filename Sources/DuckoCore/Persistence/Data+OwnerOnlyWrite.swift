import Foundation

public extension Data {
    /// Atomically writes the data to `url` owner-only (0600): a uniquely-named
    /// sibling temp file is created via `mkstemp` (0600 from creation), the
    /// bytes are written, then it is `rename`d over `url`. The file is never
    /// group/other-readable at any instant, and a partial write can't clobber
    /// an existing file. The destination directory must already exist.
    func writeOwnerOnly(to url: URL) throws {
        let finalPath = url.path
        var template = Array("\(finalPath).tmp.XXXXXX".utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw Self.ownerOnlyWriteError(path: finalPath) }
        let tempPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        var committed = false
        defer { if !committed { unlink(tempPath) } }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: self)
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()

        guard rename(tempPath, finalPath) == 0 else {
            throw Self.ownerOnlyWriteError(path: finalPath)
        }
        committed = true
    }

    private static func ownerOnlyWriteError(path: String) -> Error {
        let posixError = POSIXError(.init(rawValue: errno) ?? .ENOENT)
        return CocoaError(.fileWriteUnknown, userInfo: [
            NSFilePathErrorKey: path,
            NSUnderlyingErrorKey: posixError
        ])
    }
}
