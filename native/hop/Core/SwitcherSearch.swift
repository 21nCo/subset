import Foundation

/// Type-to-filter in the switcher: which listed items match the typed query, and in what order. The rules are closed;
/// an item matches by the first of these that holds, and better rules come first:
///
/// 1. `appNamePrefix`: the app's name starts with the query;
/// 2. `wordPrefix`: a word of the window's title or the app's name starts with the query (a word starts the text or
///    follows a character that is not a letter or digit);
/// 3. `substring`: the title or the app's name contains the query.
///
/// Every rule ignores case and diacritics, so `e` matches `É`. Items that match by the same rule keep their recency
/// order. An app cell has no title and matches by its app's name. Nothing else matches: no fuzzy or typo-tolerant
/// matching and no window contents. The query lives only in the open switcher; it is never stored or logged.
public enum SwitcherSearch {
    public enum Rule: Int, Sendable, Comparable {
        case appNamePrefix
        case wordPrefix
        case substring

        public static func < (lhs: Rule, rhs: Rule) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The items that match `query`, best rule first and in their given order within a rule; all of them, in order,
    /// for an empty query.
    public static func matches(_ query: String, in items: [SwitcherItem]) -> [SwitcherItem] {
        let needle = fold(query)
        guard !needle.isEmpty else { return items }
        return items.enumerated()
            .compactMap { offset, item in rule(folded: needle, item).map { (rule: $0, offset: offset, item: item) } }
            .sorted { ($0.rule, $0.offset) < ($1.rule, $1.offset) }
            .map(\.item)
    }

    /// The best rule by which `item` matches `query`, or nil when none does. An empty query matches nothing here.
    public static func rule(matching query: String, _ item: SwitcherItem) -> Rule? {
        let needle = fold(query)
        guard !needle.isEmpty else { return nil }
        return rule(folded: needle, item)
    }

    /// Whether a typed character can go into the query: anything printable, including a space, but no control
    /// character (Tab, Return, Esc, Delete), private-use character (the function and arrow keys), or format character.
    public static func isSearchCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }
    }

    private static func rule(folded needle: String, _ item: SwitcherItem) -> Rule? {
        let appName = fold(item.appName)
        let title = fold(item.window?.title ?? "")
        if appName.hasPrefix(needle) { return .appNamePrefix }
        if hasWord(startingWith: needle, in: title) || hasWord(startingWith: needle, in: appName) { return .wordPrefix }
        if title.contains(needle) || appName.contains(needle) { return .substring }
        return nil
    }

    private static func hasWord(startingWith needle: String, in text: String) -> Bool {
        var previous: Character?
        for index in text.indices {
            if !(previous.map(isWordCharacter) ?? false), text[index...].hasPrefix(needle) { return true }
            previous = text[index]
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Lowercased without diacritics, as every rule compares.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
