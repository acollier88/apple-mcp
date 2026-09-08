import Foundation

/// Owner-only run artifacts under `~/.config/apple-tasks/runs/`.
enum RunLogs {
    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Create (or reopen) a run log at `0600` and return a write handle.
    @discardableResult
    static func create(at path: String) -> FileHandle? {
        FileManager.default.createFile(
            atPath: path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path)
        return FileHandle(forWritingAtPath: path)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
