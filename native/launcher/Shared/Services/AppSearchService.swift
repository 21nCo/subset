import Foundation

struct AppSearchService: Sendable {
    private let applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]

    func loadApps() -> [SearchResult] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isApplicationKey, .localizedNameKey]

        return applicationDirectories.flatMap { directory -> [SearchResult] in
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            return enumerator.compactMap { item in
                // Only real application bundles, not any folder or package named *.app.
                guard let url = item as? URL,
                      url.pathExtension == "app",
                      let values = try? url.resourceValues(forKeys: resourceKeys),
                      values.isApplication == true else { return nil }
                let name = values.localizedName ?? url.deletingPathExtension().lastPathComponent
                return SearchResult.app(name: name, url: url)
            }
        }
        .uniqued(on: \.id)
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
