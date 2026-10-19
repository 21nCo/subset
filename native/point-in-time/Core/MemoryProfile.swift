import Foundation

/// `Memory.md`: the user's plain-text work profile, kept beside the store and sent (its first 8 KB) with every
/// classification request.
public struct MemoryProfile: Sendable {
    public static let template = """
        # What counts as focus

        Describe your work so pointInTime can label your time. Only the first 8 KB of this file is sent to the \
        provider you choose.

        ## My work
        - Role:
        - Current projects:

        ## Focus
        - Apps, sites, and topics that are real work:

        ## Neutral
        - Necessary but not core (email, chat, admin):

        ## Drift
        - Time you would rather not spend:

        """

    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("Memory.md")
    }

    /// Creates the file from the template (mode 0600) when it does not exist yet.
    @discardableResult
    public func ensureExists() throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: url.path, contents: Data(Self.template.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.filesystem("Could not create Memory.md")
            }
        }
        return url
    }

    /// The profile capped to `ClassificationRequest.maxMemoryBytes`, created first if needed; empty when unreadable.
    public func read() -> String {
        guard (try? ensureExists()) != nil, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        // A few bytes past the cap, so a character cut at the read's end is dropped by the cap, not decoded half.
        let data = (try? handle.read(upToCount: ClassificationRequest.maxMemoryBytes + 4)) ?? Data()
        return ClassificationRequest.cap(String(decoding: data, as: UTF8.self), bytes: ClassificationRequest.maxMemoryBytes)
    }
}
