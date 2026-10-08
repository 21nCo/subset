import Foundation

final class FileSearchService: @unchecked Sendable {
    private let fileManager = FileManager.default
    private var lastQuery = ""
    private var lastFilter: SearchFilter = .all
    private var lastResults: [SearchResult] = []

    private var searchRoots: [URL] {
        [
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.homeDirectoryForCurrentUser
        ].compactMap { $0 }.uniqued(on: \.path)
    }

    func initialFiles(limit: Int = 12) -> [SearchResult] {
        searchRoots
            .prefix(3)
            .flatMap { children(in: $0, limit: limit) }
            .uniqued(on: \.id)
            .prefix(limit)
            .map { $0 }
    }

    func searchFiles(matching query: String, limit: Int = 30) -> [SearchResult] {
        searchFiles(matching: query, filter: .files, limit: limit)
    }

    func searchFiles(matching query: String, filter: SearchFilter, limit: Int = 30) -> [SearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            lastQuery = ""
            lastResults = initialFiles(limit: limit)
            return lastResults
        }

        guard normalizedQuery.count > 1 else {
            lastQuery = normalizedQuery
            lastFilter = filter
            lastResults = []
            return []
        }

        if normalizedQuery == lastQuery, filter == lastFilter {
            return lastResults
        }

        let results = spotlightFiles(matching: normalizedQuery, filter: filter, limit: limit)
            .uniqued(on: \.id)
            .sorted { lhs, rhs in
                score(lhs, query: normalizedQuery) > score(rhs, query: normalizedQuery)
            }
            .prefix(limit)
            .map { $0 }

        lastQuery = normalizedQuery
        lastFilter = filter
        lastResults = results
        return results
    }

    private func spotlightFiles(matching query: String, filter: SearchFilter, limit: Int) -> [SearchResult] {
        let escapedQuery = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        var predicates = [
            "(kMDItemFSName == '*\(escapedQuery)*'cdw || kMDItemDisplayName == '*\(escapedQuery)*'cdw)"
        ]

        if filter == .images {
            predicates.append("kMDItemContentTypeTree == 'public.image'")
        } else if filter == .text {
            predicates.append("kMDItemContentTypeTree == 'public.text'")
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", predicates.joined(separator: " && ")]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return [] }

        return data
            .split(separator: 0)
            .prefix(limit * 2)
            .compactMap { Data($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .map { URL(fileURLWithPath: $0) }
            .filter(isSearchableFile)
            .filter { url in
                if filter == .images {
                    return SearchResult.file(url: url).isImageFile
                }
                if filter == .text {
                    return SearchResult.file(url: url).isTextFile
                }
                return true
            }
            .prefix(limit)
            .map(SearchResult.file(url:))
    }

    private func children(in directory: URL, limit: Int) -> [SearchResult] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter(isSearchableFile)
            .prefix(limit)
            .map(SearchResult.file(url:))
    }

    private func matchingFiles(in root: URL, query: String, limit: Int) -> [SearchResult] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [SearchResult] = []

        for item in enumerator {
            guard let url = item as? URL else { continue }
            guard isSearchableFile(url), url.lastPathComponent.localizedCaseInsensitiveContains(query) else {
                continue
            }

            results.append(.file(url: url))
            if results.count >= limit {
                break
            }
        }

        return results
    }

    private func isSearchableFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]) else {
            return false
        }

        if values.isHidden == true {
            return false
        }

        return values.isRegularFile == true || values.isDirectory == true
    }

    private func score(_ result: SearchResult, query: String) -> Int {
        let title = result.title.lowercased()
        let query = query.lowercased()

        if title == query { return 100 }
        if title.hasPrefix(query) { return 80 }
        if result.subtitle.contains("/Downloads") { return 20 }
        return 10
    }
}
