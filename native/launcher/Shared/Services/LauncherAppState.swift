import AppKit
import Foundation

@MainActor
final class LauncherAppState: ObservableObject {
    @Published var query = ""
    @Published var mode: LauncherMode = .search
    @Published var selectedFilter: SearchFilter = .all
    /// The floating launcher button is opt-in and remembered across launches.
    @Published var isAvatarVisible = UserDefaults.standard.bool(forKey: LauncherAppState.avatarVisibleKey)
    @Published private(set) var isLauncherOpen = false
    @Published private(set) var apps: [SearchResult] = []
    @Published private(set) var files: [SearchResult] = []
    @Published private(set) var shortcuts: [SearchResult] = []
    @Published private(set) var quickNotes: [QuickNote] = []

    static let avatarVisibleKey = "dev.subset.launcher.floatingButtonVisible"
    let persistenceController = PersistenceController.shared

    var onOpenLauncher: ((LauncherMode) -> Void)?
    var onCloseLauncher: (() -> Void)?
    var onOpenQuickNotes: (() -> Void)?
    var onAvatarVisibilityChanged: ((Bool) -> Void)?

    private let appSearchService = AppSearchService()
    private let shortcutSearchService = ShortcutSearchService()
    private let fileSearchService = FileSearchService()
    private let emojiSearchService = EmojiSearchService()
    private let windowManagementService = WindowManagementService()
    private var fileSearchTask: Task<Void, Never>?

    init() {
        quickNotes = persistenceController.fetchRecentNotes()
    }

    func refreshSearchData() {
        apps = appSearchService.loadApps()
        shortcuts = shortcutSearchService.loadShortcuts()
        files = fileSearchService.initialFiles()
    }

    func rememberWindowTarget(_ app: NSRunningApplication) {
        windowManagementService.rememberTargetApplication(app)
    }

    func openLauncher(mode: LauncherMode) {
        windowManagementService.rememberTargetApplication()
        self.mode = mode
        selectedFilter = .all
        isLauncherOpen = true
        query = ""
        files = fileSearchService.initialFiles()
        quickNotes = persistenceController.fetchRecentNotes()
        shortcuts = shortcutSearchService.loadShortcuts()
        onOpenLauncher?(mode)
    }

    func closeLauncher() {
        fileSearchTask?.cancel()
        isLauncherOpen = false
        onCloseLauncher?()
    }

    func toggleLauncher(mode: LauncherMode = .search) {
        if isLauncherOpen {
            closeLauncher()
        } else {
            openLauncher(mode: mode)
        }
    }

    func markLauncherClosed() {
        isLauncherOpen = false
    }

    func openQuickNotes() {
        quickNotes = persistenceController.fetchRecentNotes(limit: 500)
        onOpenQuickNotes?()
    }

    func toggleAvatarVisibility() {
        setAvatarVisibility(!isAvatarVisible)
    }

    func setAvatarVisibility(_ isVisible: Bool) {
        self.isAvatarVisible = isVisible
        UserDefaults.standard.set(isVisible, forKey: Self.avatarVisibleKey)
        onAvatarVisibilityChanged?(isVisible)
    }

    func saveQuickNote(title: String, body: String) {
        persistenceController.saveQuickNote(title: title, body: body)
        quickNotes = persistenceController.fetchRecentNotes(limit: 500)
    }

    func deleteQuickNote(_ note: QuickNote) {
        persistenceController.delete(note)
        quickNotes = persistenceController.fetchRecentNotes(limit: 500)
    }

    func filteredResults(for query: String) -> [SearchResult] {
        let windowResults = WindowCommand.allCases.map(SearchResult.windowCommand)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if selectedFilter == .emoji {
            return emojiSearchService.search(matching: normalizedQuery, limit: 900)
        }

        if selectedFilter == .calculator {
            return []
        }

        guard !normalizedQuery.isEmpty else {
            let initialResults = Array(apps.prefix(8))
                + Array(shortcuts.prefix(6))
                + windowResults
                + Array(files.prefix(12))

            return filterResults(Array(initialResults.prefix(30)))
        }

        let shouldShowFiles = [.all, .files, .images, .text].contains(selectedFilter)
            && !hasMatchingWindowCommand(for: normalizedQuery)
        let matchingFiles: [SearchResult] = shouldShowFiles ? files : []
        let allResults = apps + shortcuts + windowResults + matchingFiles

        return filterResults(allResults)
            .filter { result in
                result.windowCommand?.searchTerms.localizedCaseInsensitiveContains(normalizedQuery) == true
                    || result.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || result.subtitle.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .prefix(40)
            .map { $0 }
    }

    func scheduleFileSearch(for query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = selectedFilter

        fileSearchTask?.cancel()

        guard [.all, .files, .images, .text].contains(filter) else {
            return
        }

        guard !hasMatchingWindowCommand(for: normalizedQuery) else {
            return
        }

        guard normalizedQuery.count > 1 else {
            files = normalizedQuery.isEmpty ? fileSearchService.initialFiles() : []
            return
        }

        fileSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            let results = await Task.detached(priority: .userInitiated) {
                FileSearchService().searchFiles(matching: normalizedQuery, filter: filter, limit: 35)
            }.value

            guard !Task.isCancelled else { return }
            self?.files = results
        }
    }

    private func hasMatchingWindowCommand(for query: String) -> Bool {
        guard !query.isEmpty else { return false }
        return WindowCommand.allCases.contains { command in
            command.title.localizedCaseInsensitiveContains(query)
                || command.searchTerms.localizedCaseInsensitiveContains(query)
        }
    }

    private func filterResults(_ results: [SearchResult]) -> [SearchResult] {
        switch selectedFilter {
        case .all:
            return results
        case .apps:
            return results.filter { $0.kind == .app }
        case .files:
            return results.filter { $0.kind == .file }
        case .images:
            return results.filter(\.isImageFile)
        case .text:
            return results.filter(\.isTextFile)
        case .shortcuts:
            return results.filter { $0.kind == .shortcut }
        case .emoji:
            return results.filter { $0.kind == .emoji }
        case .calculator:
            return []
        }
    }

    func open(_ result: SearchResult) {
        switch result.kind {
        case .emoji:
            copy(result)
        case .app, .file:
            if let url = result.url {
                NSWorkspace.shared.open(url)
            }
        case .shortcut:
            shortcutSearchService.runShortcut(named: result.title)
        case .window:
            if let command = result.windowCommand {
                closeLauncher()
                windowManagementService.perform(command)
            }
        }
    }

    /// Reveals an app or file in Finder (⌘↩), matching Raycast and Alfred.
    func reveal(_ result: SearchResult) {
        guard let url = result.url, result.kind == .app || result.kind == .file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ result: SearchResult) {
        NSPasteboard.general.clearContents()

        if let copyText = result.copyText {
            NSPasteboard.general.setString(copyText, forType: .string)
        } else if result.isImageFile, let url = result.url, let image = NSImage(contentsOf: url) {
            NSPasteboard.general.writeObjects([image])
        } else if let url = result.url {
            NSPasteboard.general.writeObjects([url as NSURL])
        }
    }
}
