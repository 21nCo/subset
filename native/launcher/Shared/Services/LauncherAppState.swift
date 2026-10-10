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
    /// Set when a note could not be written to the local store.
    @Published var noteSaveError: String?

    static let avatarVisibleKey = "dev.subset.launcher.floatingButtonVisible"
    /// The Quick Notes window and Launcher share one list, so every fetch uses the same limit.
    static let quickNotesLimit = 500
    let persistenceController = PersistenceController.shared

    var onOpenLauncher: ((LauncherMode) -> Void)?
    var onCloseLauncher: (() -> Void)?
    var onOpenQuickNotes: (() -> Void)?
    var onAvatarVisibilityChanged: ((Bool) -> Void)?

    private let appSearchService = AppSearchService()
    private let shortcutSearchService = ShortcutSearchService()
    private let emojiSearchService = EmojiSearchService()
    private let windowManagementService = WindowManagementService()
    private var fileSearchTask: Task<Void, Never>?
    private var initialFilesScan: Task<[SearchResult], Never>?
    private var appsTask: Task<Void, Never>?
    private var shortcutsTask: Task<Void, Never>?

    init() {
        quickNotes = persistenceController.fetchRecentNotes(limit: Self.quickNotesLimit)
    }

    func refreshSearchData() {
        loadInitialFiles()
        refreshCatalogs()
    }

    /// Lists recent Downloads/Desktop/Documents items off the main actor. Reading those folders
    /// can wait on a macOS privacy prompt, which must not block launch or the launcher panel.
    /// Uses `fileSearchTask`, so a newer query search cancels publishing. The folder scan itself
    /// is single-flight: while one is running (possibly waiting on a prompt), later calls reuse it.
    private func loadInitialFiles() {
        fileSearchTask?.cancel()
        let scan = initialFilesScan ?? Task.detached(priority: .userInitiated) {
            FileSearchService().initialFiles()
        }
        initialFilesScan = scan
        fileSearchTask = Task { [weak self] in
            let results = await scan.value
            guard let self else { return }
            if self.initialFilesScan == scan { self.initialFilesScan = nil }
            guard !Task.isCancelled else { return }
            self.files = results
        }
    }

    /// Reloads apps and Siri Shortcuts off the main actor. They load independently, so a slow
    /// `shortcuts list` neither delays app results nor blocks a later app refresh.
    private func refreshCatalogs() {
        if appsTask == nil {
            let appSearchService = appSearchService
            appsTask = Task { [weak self] in
                let apps = await Task.detached(priority: .utility) { appSearchService.loadApps() }.value
                guard let self else { return }
                self.apps = apps
                self.appsTask = nil
            }
        }
        if shortcutsTask == nil {
            let shortcutSearchService = shortcutSearchService
            shortcutsTask = Task { [weak self] in
                let shortcuts = await Task.detached(priority: .utility) { shortcutSearchService.loadShortcuts() }.value
                guard let self else { return }
                self.shortcuts = shortcuts
                self.shortcutsTask = nil
            }
        }
    }

    /// Reloads notes after an external writer (an App Intent) changed the store.
    func reloadQuickNotes() {
        quickNotes = persistenceController.fetchRecentNotes(limit: Self.quickNotesLimit)
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
        noteSaveError = nil
        // A search from the previous session must not replace the fresh suggestions.
        loadInitialFiles()
        reloadQuickNotes()
        refreshCatalogs()
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
        fileSearchTask?.cancel()
        isLauncherOpen = false
    }

    func openQuickNotes() {
        reloadQuickNotes()
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

    /// Returns false if the note could not be saved; `noteSaveError` then explains why.
    @discardableResult
    func saveQuickNote(title: String, body: String) -> Bool {
        let result = persistenceController.saveQuickNote(title: title, body: body)
        reloadQuickNotes()
        if case .failure(let error) = result {
            noteSaveError = "The note could not be saved. \(error.localizedDescription)"
            return false
        }
        noteSaveError = nil
        return true
    }

    func deleteQuickNote(_ note: QuickNote) {
        persistenceController.delete(note)
        reloadQuickNotes()
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

            // Filter before capping so Images or Text still show matching suggestions.
            return Array(filterResults(initialResults).prefix(30))
        }

        // Window commands are listed ahead of files; a query such as "left" or "window" must
        // not hide files with that name.
        let shouldShowFiles = [.all, .files, .images, .text].contains(selectedFilter)
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

        guard normalizedQuery.count > 1 else {
            if normalizedQuery.isEmpty {
                loadInitialFiles()
            } else {
                files = []
            }
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
