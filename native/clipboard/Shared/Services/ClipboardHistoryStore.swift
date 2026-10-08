import Foundation

@MainActor
final class ClipboardHistoryStore {
    private let fileManager: FileManager
    private let historyURL: URL

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
        do {
            let data = try Data(contentsOf: historyURL)
            let decoder = JSONDecoder()
            return try decoder.decode([ClipboardItem].self, from: data)
        } catch {
            return []
        }
    }

    func save(_ items: [ClipboardItem]) {
        do {
            let folderURL = historyURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            // Best-effort persistence; a failed write keeps the in-memory history.
        }
    }
}
