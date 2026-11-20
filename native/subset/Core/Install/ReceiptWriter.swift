import Darwin
import Foundation

/// The `subset.receipt@1` receipt an install or update writes, in exactly the text the `subset` command writes
/// (`JSON.stringify(document, null, 2)` and a newline, keys in its order), so either reads what the other wrote.
struct ReceiptDocument: Sendable {
    /// ~/Library/Application Support/Subset/receipts/<bundleId>.json.
    var file: URL
    var channel: ReleaseChannel
    var version: String
    var build: Int?
    var sha256: String
    /// The installed `.app` as receipts name it: /Applications/<appName>.app or /Users/<user>/Applications/<appName>.app.
    var path: String

    /// The receipt for installing `release` of `app` into `folder`, or nil when the schema cannot hold its path (a home
    /// folder outside /Users), in which case none is written, as `receiptFor` in install.mjs decides.
    init?(_ app: CatalogApp, _ release: ChosenRelease, folder: ApplicationsFolder, receipts: URL) {
        file = receipts.appendingPathComponent("\(app.bundleID).json")
        channel = release.channel
        version = release.version
        build = release.build
        sha256 = release.sha256
        path = "\(folder.path)/\(app.appName).app"
        guard case .success = Receipt.parse(text(installedAt: Date(timeIntervalSince1970: 0))) else { return nil }
    }

    /// The receipt's text with `installedAt` (a UTC time to the second).
    func text(installedAt date: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        var fields = [("schema", Self.json(Receipt.schema)), ("channel", Self.json(channel.rawValue)), ("version", Self.json(version))]
        if let build { fields.append(("build", String(build))) }
        fields += [("sha256", Self.json(sha256)), ("installedAt", Self.json(formatter.string(from: date))), ("path", Self.json(path))]
        return Data(("{\n" + fields.map { "  \"\($0)\": \($1)" }.joined(separator: ",\n") + "\n}\n").utf8)
    }

    /// Writes the receipt with `installedAt` to a new temporary file beside it and returns that file; `commit` renames it
    /// into place. Throws an InstallFailure (step receipt).
    func writeTemporary(installedAt date: Date) throws -> URL {
        let folder = file.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".receipt.\(getpid()).\(AppLock.random().prefix(8)).tmp")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: text(installedAt: date))
                try handle.close()
            } catch {
                unlink(temporary.path)
                throw error
            }
        } catch {
            throw InstallFailure(.receipt, "the receipt \(file.path) cannot be written (\(error.localizedDescription))")
        }
        return temporary
    }

    /// `text` as a JSON string, escaped as JSON.stringify escapes it.
    static func json(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
