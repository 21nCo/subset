import Foundation

/// An install receipt, `subset.receipt@1` (`packages/catalog/README.md`): what `subset` or this app installed, kept at
/// `~/Library/Application Support/Subset/receipts/<bundleId>.json`. Advisory only: the installed app's own Info.plist
/// says what is installed, and a missing or invalid receipt is simply not used.
public struct Receipt: Equatable, Sendable {
    public static let schema = "subset.receipt@1"
    static let maxBytes = 64 * 1024

    public var channel: ReleaseChannel
    public var version: String
    /// The beta build, present exactly when `channel` is beta.
    public var build: Int?
    public var sha256: String
    public var installedAt: String
    /// The installed `.app`, directly inside /Applications or /Users/<user>/Applications.
    public var path: String

    /// The receipt in `data`, or the problems that refuse it: not UTF-8 JSON or invalid against the closed schema.
    public static func parse(_ data: Data) -> Result<Receipt, FeedRefusal> {
        if data.count > maxBytes { return .failure(FeedRefusal(["the receipt is larger than \(maxBytes) bytes"])) }
        let json: Any
        switch JSONChecker.parse(data) {
        case .success(let value): json = value
        case .failure(let refusal): return .failure(refusal)
        }
        var checker = JSONChecker()
        let keys = ["schema", "channel", "version", "sha256", "installedAt", "path"]
        guard let receipt = checker.object(json, "", required: keys, optional: ["build"]) else {
            return .failure(FeedRefusal(checker.problems))
        }
        let schemaOK = checker.constant(receipt["schema"], "/schema", schema)
        let channel = checker.oneOf(receipt["channel"], "/channel", ["live", "beta"]).flatMap(ReleaseChannel.init(rawValue:))
        let version = checker.string(receipt["version"], "/version", pattern: .version)
        let build = receipt["build"].flatMap { checker.integer($0, "/build", in: 1...999_999_999) }
        let sha256 = checker.string(receipt["sha256"], "/sha256", pattern: .sha256)
        let installedAt = checker.string(receipt["installedAt"], "/installedAt", pattern: .utcTimestamp)
        let path = checker.string(receipt["path"], "/path", pattern: .receiptPath, maxLength: 1024)
        if channel == .beta, receipt["build"] == nil { checker.fail("", "a beta receipt must have a build") }
        if channel == .live, receipt["build"] != nil { checker.fail("/build", "a live receipt must not have a build") }
        guard schemaOK, let channel, let version, let sha256, let installedAt, let path, checker.problems.isEmpty else {
            return .failure(FeedRefusal(checker.problems))
        }
        return .success(
            Receipt(channel: channel, version: version, build: build, sha256: sha256, installedAt: installedAt, path: path)
        )
    }
}

/// A release channel of the feed.
public enum ReleaseChannel: String, Equatable, Sendable {
    case live
    case beta
}
