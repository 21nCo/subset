import EmojiKit
import Foundation

struct EmojiSearchService {
    private let locale = Locale(identifier: "en")

    func search(matching query: String, limit: Int = 900) -> [SearchResult] {
        let normalizedQuery = query.normalizedEmojiSearchText
        let results: [Emoji]

        if normalizedQuery.isEmpty || normalizedQuery == "emoji" {
            results = Emoji.all
        } else {
            results = Emoji.all
                .map { emoji in
                    (emoji: emoji, score: score(emoji, for: normalizedQuery))
                }
                .filter { $0.score > 0 }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return lhs.emoji.localizedName(in: locale) < rhs.emoji.localizedName(in: locale)
                    }
                    return lhs.score > rhs.score
                }
                .map(\.emoji)
        }

        return results
            .uniqued(on: \.char)
            .prefix(limit)
            .map { emoji in
                SearchResult.emoji(symbol: emoji.char, name: emoji.localizedName(in: locale))
            }
    }

    private func score(_ emoji: Emoji, for query: String) -> Int {
        if emoji.char == query {
            return 1_000
        }

        let name = emoji.localizedName(in: locale).normalizedEmojiSearchText
        let unicodeName = emoji.unicodeName.normalizedEmojiSearchText
        let annotations = EmojiAnnotationIndex.annotations[emoji.char, default: []]
            .map(\.normalizedEmojiSearchText)
        let searchableFields = [name, unicodeName] + annotations
        let terms = query.split(separator: " ").map(String.init)

        if searchableFields.contains(query) {
            return 900
        }

        if searchableFields.contains(where: { $0.hasPrefix(query) }) {
            return 700
        }

        if searchableFields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            return 500
        }

        if terms.allSatisfy({ term in searchableFields.contains(where: { $0.localizedCaseInsensitiveContains(term) }) }) {
            return 350
        }

        return 0
    }
}

private extension String {
    var normalizedEmojiSearchText: String {
        // Every searchable field is English, so fold with the same locale (e.g. Turkish "I").
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
