import Darwin
import Foundation

enum BoundedFile {
    /// At most `limit + 1` bytes of the regular file at `path`, so an oversized file is known to be too large without
    /// reading it all; nil when it cannot be read. A symbolic link at `path`, a folder, a named pipe or a device is not
    /// read (the file is opened without following a link or waiting for a writer).
    static func read(_ path: String, limit: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data(count: limit + 1)
        var size = 0
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            while size < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress! + size, buffer.count - size)
                if count == 0 { return true }
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                size += count
            }
            return true
        }
        guard complete else { return nil }
        data.count = size
        return data
    }

    /// Whether `path` is itself a folder (not a symbolic link to one).
    static func isDirectory(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }
}
