import CryptoKit
import Darwin
import Foundation

/// Redacts what Explain sends to a provider (shared with SET-50's OpenRouter provider). The home folder is sent as `~`
/// and the account name is removed. Folder names deeper than the first level under `~` are replaced with placeholders
/// unless the user turns on **Send folder names**, the item being explained's own name included; the only exception is
/// macOS's own folders directly in `~/Library` (`libraryFolders`), whose names say nothing about the user. Command-line
/// arguments and file contents are never sent: System never reads them.
public struct ExplainRedactor: Sendable {
    /// What an account name is replaced with.
    public static let accountPlaceholder = "[user]"
    /// macOS's own folders directly in `~/Library`, whose names say nothing about the user.
    public static let libraryFolders: Set<String> = Set(LibraryFolder.allCases.map(\.rawValue)).union([
        "Developer", "LaunchAgents", "Saved Application State", "WebKit", "Application Scripts", "Cookies"
    ])

    /// The home folder's paths, longest first: as macOS reports it and its real path.
    let homes: [String]
    /// The account's short and full names, longest first.
    let accountNames: [String]
    public let sendFolderNames: Bool
    /// Keys the placeholders, so a folder name gets the same placeholder in every request this session and the
    /// placeholder does not reveal the name.
    private let key: [UInt8]

    public init(homes: [String], accountNames: [String], sendFolderNames: Bool, key: [UInt8]) {
        let homes = homes.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty && $0 != "/" }
        self.homes = Array(Set(homes)).sorted { $0.count > $1.count }
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
    public func path(_ path: String) -> String {
        guard let rest = homeRelative(path) else { return removingAccountNames(path) }
        return shown(rest.split(separator: "/").map(String.init))
    }

    /// The last name of a path as sent: a placeholder when the path is under the home folder deeper than the first
    /// level and folder names are not sent.
    public func name(ofPath path: String) -> String {
        self.path(path).split(separator: "/").last.map(String.init) ?? "~"
    }

    /// An item's name as sent: `name` when its path's last name is sent, otherwise that name's placeholder, so a
    /// folder's own name is withheld the same way as in its path.
    public func name(_ name: String, ofPath path: String) -> String {
        guard let parts = homeRelative(path)?.split(separator: "/"), let last = parts.last else { return name }
        return isSent(String(last), at: parts.count - 1, under: parts.first) ? name : placeholder(String(last))
    }

    /// Whether the path is the home folder or inside it.
    public func isInHome(_ path: String) -> Bool {
        homeRelative(path) != nil
    }

    /// Free text as sent: the home folder's path shown as `~`, folder names in each `~/…` path withheld as `path(_:)`
    /// withholds them, and account names removed. Paths in the text should already have been passed through `path(_:)`
    /// (a placeholder is kept as it is); this is the last line of defense. A path in free text ends at whitespace or
    /// quoting punctuation, apart from `~/Library`'s own folder names, so a folder name with a space is only partly
    /// withheld here: callers redact such paths whole first.
    public func text(_ text: String) -> String {
        var result = text
        for home in homes {
            result = result.replacingOccurrences(of: home + "/", with: "~/")
            result = Self.replacing(home, in: result, with: "~", caseInsensitive: false)
        }
        if !sendFolderNames {
            let matches = Self.homePathPattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                var found = result[range].dropFirst(2)
                var trailing = ""
                while let last = found.last, ".:!?".contains(last) {
                    trailing = String(last) + trailing
                    found = found.dropLast()
                }
                result.replaceSubrange(range, with: shown(found.split(separator: "/").map(String.init)) + trailing)
            }
        }
        return removingAccountNames(result)
    }

    func placeholder(_ name: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: key))
        return "folder-" + code.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// A `~/…` path in free text: components up to whitespace, a slash, or quoting punctuation, or one of `~/Library`'s
    /// own folder names that has a space.
    private static let homePathPattern: NSRegularExpression = {
        let spaced = libraryFolders.filter { $0.contains(" ") }.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
        let component = "(?:" + (spaced + ["[^/\\s`'\"“”‘’,;()]+"]).joined(separator: "|") + ")"
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}~/])~(?:/" + component + ")+")
    }()

    /// Home-relative components as sent.
    private func shown(_ parts: [String]) -> String {
        let shown = parts.enumerated().map { position, part in
            isSent(part, at: position, under: parts.first.map { Substring($0) }) ? removingAccountNames(part) : placeholder(part)
        }
        return (["~"] + shown).joined(separator: "/")
    }

    /// Whether a home-relative component is sent by name: the first level, `~/Library`'s own folders, every name with
    /// **Send folder names** on, and a placeholder already made, so redacting twice changes nothing.
    private func isSent(_ part: String, at position: Int, under first: Substring?) -> Bool {
        position == 0 || sendFolderNames || (position == 1 && first == "Library" && Self.libraryFolders.contains(part))
            || isPlaceholder(part)
    }

    private func isPlaceholder(_ part: String) -> Bool {
        part.count == 13 && part.hasPrefix("folder-") && part.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func homeRelative(_ path: String) -> String? {
        for home in homes {
            if path == home { return "" }
            if path.hasPrefix(home + "/") { return String(path.dropFirst(home.count + 1)) }
        }
        return nil
    }

    private func removingAccountNames(_ text: String) -> String {
        accountNames.reduce(text) { Self.replacing($1, in: $0, with: Self.accountPlaceholder, caseInsensitive: true) }
    }

    /// Replaces `word` where no letter or digit adjoins it, so a short name inside a longer word is left alone.
    private static func replacing(_ word: String, in text: String, with replacement: String, caseInsensitive: Bool) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
