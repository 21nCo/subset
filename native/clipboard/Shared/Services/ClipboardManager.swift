import AppKit
import Foundation

@MainActor
final class ClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipboardItem]
    @Published var searchQuery = ""
    @Published private(set) var statusMessage = "Clipboard monitor ready."
    @Published private(set) var isCapturePaused = false
    @Published private(set) var permissionStatus = "Checking Accessibility permission..."

    private let store: ClipboardHistoryStore
    private let monitor: ClipboardMonitor
    private let maximumHistoryCount = 250
    private var lastExternalTarget: ActiveAppTarget?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?

    init(
        store: ClipboardHistoryStore = ClipboardHistoryStore(),
        monitor: ClipboardMonitor = ClipboardMonitor(),
        startsMonitoring: Bool = true
    ) {
        self.store = store
        self.monitor = monitor
        self.items = store.load().sorted { $0.capturedAt > $1.capturedAt }

        observeActiveApplications()
        refreshPermissionStatus()
        if startsMonitoring {
            startMonitoring()
        }
    }

    var filteredItems: [ClipboardItem] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return items }

        return items.filter { item in
            item.searchableText.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var hasAccessibilityPermission: Bool {
        ActiveAppPasteService.hasAccessibilityTrust()
    }

    func resetSearch() {
        searchQuery = ""
    }

    func toggleCapturePaused() {
        isCapturePaused.toggle()
        monitor.setPaused(isCapturePaused)
        report(status: isCapturePaused ? "Clipboard capture paused." : "Clipboard capture resumed.")
    }

    func clearHistory() {
        items.removeAll(keepingCapacity: false)
        store.save(items)
        report(status: "Clipboard history cleared.")
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        store.save(items)
        report(status: "Removed \(item.kind.displayName.lowercased()) from history.")
    }

    func paste(_ item: ClipboardItem, to target: ActiveAppTarget?) async {
        monitor.ignoreNextCapture(for: item)

        do {
            try await ActiveAppPasteService.paste(item: item, to: target ?? currentPasteTarget())
            report(status: "Pasted \(item.kind.displayName.lowercased()) into the previously active app.")
        } catch {
            report(status: error.localizedDescription)
        }

        refreshPermissionStatus()
    }

    func currentPasteTarget() -> ActiveAppTarget? {
        ActiveAppPasteService.captureTarget() ?? lastExternalTarget
    }

    func refreshPermissionState() {
        refreshPermissionStatus()
    }

    func openAccessibilitySettings() {
        ActiveAppPasteService.openAccessibilitySettings()
        report(status: "Enable Accessibility for Clipboard, then return here and try again.")
    }

    func report(status: String) {
        statusMessage = status
        refreshPermissionStatus()
    }

    private func startMonitoring() {
        monitor.start { [weak self] item in
            self?.handleCapture(item)
        }
    }

    private func handleCapture(_ item: ClipboardItem) {
        if let existingIndex = items.firstIndex(where: { $0.signature == item.signature }) {
            items.remove(at: existingIndex)
        }

        items.insert(item, at: 0)

        if items.count > maximumHistoryCount {
            items.removeLast(items.count - maximumHistoryCount)
        }

        store.save(items)
        report(status: "Saved \(item.kind.displayName.lowercased()) from \(item.sourceAppName ?? "another app").")
    }

    private func observeActiveApplications() {
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                return
            }

            Task { @MainActor [weak self] in
                self?.lastExternalTarget = ActiveAppTarget(application: application)
            }
        }

        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStatus()
            }
        }
    }

    private func refreshPermissionStatus() {
        permissionStatus = hasAccessibilityPermission
            ? "Accessibility granted"
            : "Accessibility needed"
    }
}
