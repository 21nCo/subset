import Foundation

@MainActor
final class ClipboardHistoryStore {
    private let fileManager: FileManager
    private let historyURL: URL
    /// Set when the history file existed but could not be read; the unreadable file is moved
    /// aside instead of being overwritten.
    private(set) var lastLoadIssue: String?

    init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        appGroupIdentifier: String? = nil,
        namespace: String = "dev.subset.clipboard"
    ) {
        self.fileManager = fileManager

        let supportDirectory: URL
        if let baseDirectory {
            supportDirectory = baseDirectory
        } else if let appGroupIdentifier,
                  let groupDirectory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            supportDirectory = groupDirectory
        } else {
            supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        }

        let folderURL = supportDirectory.appendingPathComponent(namespace, isDirectory: true)
        self.historyURL = folderURL.appendingPathComponent("history.json")
    }

    func load() -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        coordinate(writing: false) { url in items = readItems(at: url) }
        return items
    }

    @discardableResult
    func save(_ items: [ClipboardItem]) -> Bool {
        var saved = false
        coordinate(writing: true) { url in saved = write(items, to: url) }
        return saved
    }

    /// Reads, transforms, and writes the history under one file-coordination write, so the
    /// host app and the keyboard extension cannot overwrite each other's new items.
    /// Returns the saved items, or nil if the write failed.
    @discardableResult
    func update(_ transform: ([ClipboardItem]) -> [ClipboardItem]) -> [ClipboardItem]? {
        var result: [ClipboardItem]?
        coordinate(writing: true) { url in
            let updated = transform(readItems(at: url))
            result = write(updated, to: url) ? updated : nil
        }
        return result
    }

    private func coordinate(writing: Bool, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        if writing {
            coordinator.coordinate(writingItemAt: historyURL, options: [], error: &coordinationError, byAccessor: body)
        } else {
            coordinator.coordinate(readingItemAt: historyURL, options: [], error: &coordinationError, byAccessor: body)
        }
        if coordinationError != nil { body(historyURL) }
    }

    private func readItems(at url: URL) -> [ClipboardItem] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            // Keep the unreadable file for recovery rather than overwriting it on the next save.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backupURL = url.deletingLastPathComponent().appendingPathComponent("history-unreadable-\(stamp).json")
            try? fileManager.moveItem(at: url, to: backupURL)
            lastLoadIssue = "The clipboard history file could not be read; it was kept as \(backupURL.lastPathComponent)."
            return []
        }
    }

    private func write(_ items: [ClipboardItem], to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
