import CryptoKit
import Darwin
import Foundation

/// Redacts what Explain sends to a provider (shared with SET-50's OpenRouter provider). Only path values are
/// redacted, component by component: the home folder is sent as `~`, account names are removed, and folder names
/// deeper than the first level under `~` are replaced with placeholders unless the user turns on **Send folder names**,
/// the item being explained's own name included; the only exception is macOS's own folders directly in `~/Library`
/// (`libraryFolders`), whose names say nothing about the user. A request holds no free text for paths to hide in
/// (`ExplainRequest`), so nothing is scanned for paths. A process is named as macOS reports it, by its executable, even
/// when that name matches a folder withheld in its path. Command-line arguments and file contents are never sent:
/// System never reads them.
public struct ExplainRedactor: Sendable {
    /// What an account name is replaced with.
    public static let accountPlaceholder = "[user]"
    /// What Settings says under **Send folder names**.
    public static let folderNamesCaption = "When off, folder names deeper than the first level under your home folder "
        + "are sent as placeholders such as folder-3fa2c1, in paths and in the names taken from them, the explained "
        + "folder's, file's, project's, or app's own name included. A process is still named by its executable, as "
        + "macOS reports it, even when that name matches a withheld folder. Only macOS's own folders in ~/Library, such "
        + "as Caches, are sent by name."
    /// macOS's own folders directly in `~/Library`, whose names say nothing about the user.
    public static let libraryFolders: Set<String> = Set(LibraryFolder.allCases.map(\.rawValue)).union([
        "Developer", "LaunchAgents", "Saved Application State", "WebKit", "Application Scripts", "Cookies"
    ])

    /// Where the Data volume is also mounted, so `/System/Volumes/Data/Users/<name>` is the home folder too.
    static let dataVolume = "/System/Volumes/Data"

    /// The home folder's paths, longest first: as macOS reports it and its real path, each also through the Data
    /// volume's firmlink.
    let homes: [String]
    /// The account's short and full names, longest first.
    let accountNames: [String]
    public let sendFolderNames: Bool
    /// Keys the placeholders, so a folder name gets the same placeholder in every request this session and the
    /// placeholder does not reveal the name.
    private let key: [UInt8]

    public init(homes: [String], accountNames: [String], sendFolderNames: Bool, key: [UInt8]) {
        let homes = homes.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty && $0 != "/" }
        let onDataVolume = homes.filter { $0.hasPrefix("/") && !$0.hasPrefix(Self.dataVolume + "/") }.map { Self.dataVolume + $0 }
        self.homes = Array(Set(homes + onDataVolume)).sorted { $0.count > $1.count }
        self.accountNames = Array(Set(accountNames.filter { !$0.isEmpty })).sorted { $0.count > $1.count }
        self.sendFolderNames = sendFolderNames
        self.key = key
    }

    /// This Mac's home folder and account, with a key made for this session.
    public static func live(sendFolderNames: Bool, key: [UInt8]) -> ExplainRedactor {
        let home = NSHomeDirectory()
        var homes = [home]
        if let real = realpath(home, nil) {
            homes.append(String(cString: real))
            free(real)
        }
        return ExplainRedactor(homes: homes, accountNames: [NSUserName(), NSFullUserName()],
                               sendFolderNames: sendFolderNames, key: key)
    }

    /// A random key for one session's placeholders.
    public static func sessionKey() -> [UInt8] {
        SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
    }

    /// The same redactor with the **Send folder names** setting changed.
    public func sendingFolderNames(_ send: Bool) -> ExplainRedactor {
        ExplainRedactor(homes: homes, accountNames: accountNames, sendFolderNames: send, key: key)
    }

    /// A path as sent. A path outside the home folder only has account names removed.
    public func path(_ path: String) -> ExplainPath {
        guard let rest = homeRelative(path) else { return ExplainPath(removingAccountNames(path)) }
        let parts = rest.split(separator: "/").map(String.init)
        let shown = parts.enumerated().map { position, part in
            isSent(part, at: position, under: parts.first) ? removingAccountNames(part) : placeholder(part)
        }
        return ExplainPath((["~"] + shown).joined(separator: "/"))
    }

    /// The last name of a path as sent: a placeholder when the path is under the home folder deeper than the first
    /// level and folder names are not sent.
    public func name(ofPath path: String) -> String {
        self.path(path).value.split(separator: "/").last.map(String.init) ?? "~"
    }

    /// An item's name as sent: `name` when its path's last name is sent, otherwise that name's placeholder, so a
    /// folder's own name is withheld the same way as in its path.
    public func name(_ name: String, ofPath path: String) -> String {
        guard let parts = homeRelative(path)?.split(separator: "/").map(String.init), let last = parts.last else { return name }
        return isSent(last, at: parts.count - 1, under: parts.first) ? name : placeholder(last)
    }

    /// Whether the path is the home folder or inside it.
    public func isInHome(_ path: String) -> Bool {
        homeRelative(path) != nil
    }

    /// A name or identifier as sent: account names removed wherever they stand as a word.
    func removingAccountNames(_ text: String) -> String {
        accountNames.reduce(text) { Self.replacing($1, in: $0, with: Self.accountPlaceholder) }
    }

    func placeholder(_ name: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: key))
        return "folder-" + code.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a home-relative component is sent by name: the first level, `~/Library`'s own folders, and every name
    /// with **Send folder names** on.
    private func isSent(_ part: String, at position: Int, under first: String?) -> Bool {
        position == 0 || sendFolderNames || (position == 1 && first == "Library" && Self.libraryFolders.contains(part))
    }

    /// The path below the home folder, matched in any case as APFS does; `""` for the home folder itself.
    private func homeRelative(_ path: String) -> String? {
        for home in homes {
            guard let match = path.range(of: home, options: [.anchored, .caseInsensitive]) else { continue }
            if match.upperBound == path.endIndex { return "" }
            if path[match.upperBound] == "/" { return String(path[path.index(after: match.upperBound)...]) }
        }
        return nil
    }

    /// Replaces `word`, in any case, where no letter or digit adjoins it, so a short name inside a longer word is left
    /// alone.
    private static func replacing(_ word: String, in text: String, with replacement: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

/// A path as Explain sends it, made only by `ExplainRedactor.path(_:)`: a request's paths are values of their own, never
/// part of other text.
public struct ExplainPath: Encodable, Hashable, Sendable, CustomStringConvertible {
    public let value: String

    init(_ value: String) {
        self.value = value
    }

    public var description: String { value }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
