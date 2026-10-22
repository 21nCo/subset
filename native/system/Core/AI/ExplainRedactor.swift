import CryptoKit
import Darwin
import Foundation

/// Redacts what Explain sends to a provider (shared with SET-50's OpenRouter provider). The home folder is sent as `~`
/// and the account name is removed. Folder names deeper than the first level under `~` are replaced with placeholders
/// unless the user turns on **Send folder names**, the item being explained's own name included; the only exception is
/// macOS's own folders directly in `~/Library` (`libraryFolders`), whose names say nothing about the user. A process is
/// named as macOS reports it, by its executable, even when that name matches a folder withheld in its path. Command-line
/// arguments and file contents are never sent: System never reads them.
public struct ExplainRedactor: Sendable {
    /// What an account name is replaced with.
    public static let accountPlaceholder = "[user]"
    /// What Settings says under **Send folder names**.
    public static let folderNamesCaption = "When off, folder names deeper than the first level under your home folder "
        + "are sent as placeholders such as folder-3fa2c1 in paths, names, and any text that mentions a path, the "
        + "explained folder's, file's, project's, or app's own name included. A process is still named by its "
        + "executable, as macOS reports it, even when that name matches a withheld folder. Only macOS's own folders in "
        + "~/Library, such as Caches, are sent by name."
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
    /// or `paths(in:known:)` where the text was built (a placeholder is kept as it is); this is the last line of
    /// defense, and it fails closed: a folder name may hold spaces, so a `~/…` path runs to the end of its clause, and
    /// a last component that is neither a placeholder nor one of `~/Library`'s own folders is withheld through that
    /// end, words after it included. A clause end found by punctuation may be inside that name (`Acme Inc. Holdings`),
    /// so such a name is withheld on through its line or to the next path.
    public func text(_ text: String) -> String {
        var result = text
        for home in homes {
            result = result.replacingOccurrences(of: home + "/", with: "~/")
            result = Self.replacing(home, in: result, with: "~", caseInsensitive: false)
        }
        if !sendFolderNames { result = withholdingDeepNames(in: result) }
        return removingAccountNames(result)
    }

    /// `text` with each path in it that is one of `known` (raw paths, such as the folders a scan read) shown as
    /// `path(_:)` shows it, the longest that matches at each place. A known path names a folder whole, spaces included,
    /// so text built from it keeps its words after the path.
    public func paths(in text: String, known: [String]) -> String {
        let known = known.filter { homeRelative($0) != nil }.sorted { $0.count > $1.count }
        guard !known.isEmpty else { return text }
        var result = ""
        var rest = text[...]
        while let match = homes.compactMap({ rest.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            result += rest[..<match.lowerBound]
            let at = rest[match.lowerBound...]
            if let path = known.first(where: { at.hasPrefix($0) && Self.endsName(at.dropFirst($0.count)) }) {
                result += self.path(path)
                rest = at.dropFirst(path.count)
            } else {
                result += rest[match]
                rest = rest[match.upperBound...]
            }
        }
        return result + rest
    }

    func placeholder(_ name: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: key))
        return "folder-" + code.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// Each `~/…` path in `text` with its deep folder names withheld. A path runs from `~/` to the end of its clause
    /// (`clauseEnd`). Each component a slash follows is shown as `path(_:)` shows it; the last component, which may run
    /// on into the clause's words, is kept only when it starts with a placeholder or, directly in `~/Library`, one of
    /// macOS's own folders, and is otherwise withheld whole.
    private func withholdingDeepNames(in text: String) -> String {
        var result = ""
        var rest = text[...]
        while let start = rest.range(of: "~/") {
            result += rest[..<start.upperBound]
            let path = rest[start.upperBound...]
            var end = Self.clauseEnd(in: path)
            var parts = path[..<end].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count > 1 {
                let first = Substring(parts[0])
                for position in 1..<parts.count - 1
                where !parts[position].isEmpty && !isSent(parts[position], at: position, under: first) {
                    parts[position] = placeholder(parts[position])
                }
                var last = parts[parts.count - 1]
                if !last.isEmpty, !startsWithSentName(last, at: parts.count - 1, under: first) {
                    // Punctuation may end the clause inside the name (`Acme Inc. Holdings`): any words after it in
                    // the line, up to another path, are withheld with it.
                    let through = end < path.endIndex && Self.clausePunctuation.contains(path[end])
                        ? Self.lineOrPathEnd(in: path[end...]) : end
                    if path[end..<through].contains(where: { $0.isLetter || $0.isNumber }) {
                        last += path[end..<through]
                        end = through
                    }
                    parts[parts.count - 1] = placeholder(last)
                }
            }
            result += parts.joined(separator: "/")
            rest = path[end...]
        }
        return result + rest
    }

    /// Whether a path's last component in free text starts with a name sent as it is, a placeholder or one of
    /// `~/Library`'s own folders, that only the text's words then follow.
    private func startsWithSentName(_ part: String, at position: Int, under first: Substring) -> Bool {
        if isPlaceholder(String(part.prefix(13))), !Self.continuesName(part.dropFirst(13).first) { return true }
        guard position == 1, first == "Library" else { return false }
        return Self.libraryFolders.contains { part.hasPrefix($0) && !Self.continuesName(part.dropFirst($0.count).first) }
    }

    /// Where a path in free text ends: at a line break; before a space that starts another `~/` path; or at `;`, a
    /// backtick, a closing bracket, or a full stop that ends the clause, that is, one not followed by a letter, digit,
    /// slash, or name punctuation, so `Notes.app`, `v1.2`, and `Photos (old)/` stay in the path. It fails closed: a
    /// clause end that a slash follows before the next path starts (`Acme Inc. Holdings/x`, `Photos (Paris) backup/x`)
    /// is inside a folder name, so the path goes on.
    private static func clauseEnd(in text: Substring) -> Substring.Index {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { return index }
            let next = text.index(after: index)
            if character.isWhitespace, text[next...].hasPrefix("~/") { return index }
            if clausePunctuation.contains(character), next == text.endIndex || !continuesName(text[next]) && text[next] != "/",
               !slashBeforeNextPath(text[next...]) {
                return index
            }
            index = next
        }
        return index
    }

    /// What may end a clause, and so a path, in free text.
    private static let clausePunctuation = ";`)]}."

    /// Where `text`, after a clause end, reaches a line break or a space that starts another path.
    private static func lineOrPathEnd(in text: Substring) -> Substring.Index {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { return index }
            let next = text.index(after: index)
            if character.isWhitespace, startsPath(text[next...]) { return index }
            index = next
        }
        return index
    }

    /// Whether `text`, after a clause end, has a slash before a line break or the start of another path, so the
    /// clause end was part of a folder name.
    private static func slashBeforeNextPath(_ text: Substring) -> Bool {
        text[..<lineOrPathEnd(in: text)].contains("/")
    }

    /// Whether `text` starts another path after a space: `~/` or `/`, alone or after an opening backtick, bracket, or
    /// quote.
    private static func startsPath(_ text: Substring) -> Bool {
        let path = text.first.map { "`([{\"'".contains($0) } == true ? text.dropFirst() : text
        return path.hasPrefix("~/") || path.hasPrefix("/")
    }

    /// Whether a name ends where `after` starts: what follows is not part of a name, or is a full stop that ends a
    /// sentence rather than starting an extension (`Holdings.` but not `Notes.app`).
    private static func endsName(_ after: Substring) -> Bool {
        guard let next = after.first, continuesName(next) else { return true }
        return next == "." && !continuesName(after.dropFirst().first)
    }

    /// Whether a character after a name is still part of it.
    private static func continuesName(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || "-_.".contains(character)
    }

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
