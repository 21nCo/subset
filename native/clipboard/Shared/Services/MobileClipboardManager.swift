#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class MobileClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipboardItem]
    @Published private(set) var pasteboardPreview: ClipboardItem?
    @Published var statusMessage = "Clipboard syncs automatically when this app or keyboard opens."

    private static let maximumHistoryCount = 200
    private let store: ClipboardHistoryStore
    private let autoSync: ClipboardAutoSync
    private var notificationTokens: [NSObjectProtocol] = []

    init(
        store: ClipboardHistoryStore = ClipboardHistoryStore(
            appGroupIdentifier: SharedContainer.appGroupIdentifier,
            namespace: SharedContainer.historyNamespace
        )
    ) {
        self.store = store
        self.autoSync = ClipboardAutoSync(store: store, maximumHistoryCount: Self.maximumHistoryCount)
        self.items = store.load().sorted { $0.capturedAt > $1.capturedAt }
        registerAutomaticSyncObservers()
        // Automatic syncs are gated on the pasteboard change count, so an unchanged clipboard
        // is not re-read (each read can show the iOS "Allow Paste" prompt).
        refresh(forceSync: false)
    }

    var keyboardSubtitle: String {
        items.isEmpty ? "Copy something, then open the keyboard" : "\(items.count) ready for the keyboard"
    }

    func refresh(forceSync: Bool = false) {
        let syncResult = autoSync.syncIfNeeded(force: forceSync)
        reloadItems(syncResult: syncResult)
        updateStatus(from: syncResult, forceSync: forceSync)
    }

    func syncCurrentClipboardNow() {
        refresh(forceSync: true)
    }

    func clearHistory() {
        items.removeAll(keepingCapacity: false)
        let saved = store.save(items)
        pasteboardPreview = nil
        statusMessage = saved
            ? "Cleared the shared iPhone/iPad clipboard history."
            : "Could not update the shared history file."
    }

    /// Copies a saved clip back to the system clipboard so it can be pasted in any app.
    func copyToClipboard(_ item: ClipboardItem) {
        guard item.write(to: UIPasteboard.general) else {
            statusMessage = "Could not restore that \(item.kind.displayName.lowercased()) to the clipboard."
            return
        }
        // Our own write must not come back as a new or re-timed history entry.
        autoSync.markCurrentPasteboardSynced()
        switch item.kind {
        case .text, .url:
            statusMessage = "Copied \(item.kind.displayName.lowercased()) to the clipboard. Paste it anywhere."
        case .image:
            statusMessage = "Photo copied to the clipboard."
        case .files:
            statusMessage = "File link copied. Other apps can open it only if they can access that location."
        }
    }

    private func registerAutomaticSyncObservers() {
        let center = NotificationCenter.default

        notificationTokens.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh(forceSync: false)
                }
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: UIPasteboard.changedNotification,
                object: UIPasteboard.general,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh(forceSync: false)
                }
            }
        )
    }

    private func reloadItems(syncResult: ClipboardAutoSyncResult) {
        items = store.load().sorted { $0.capturedAt > $1.capturedAt }
        // "Current Clipboard" shows only what was actually read from the pasteboard; when the
        // pasteboard was not re-read, keep the previous preview instead of a historical clip.
        if let synced = syncResult.syncedItem {
            pasteboardPreview = synced
        } else if syncResult.didReadPasteboard {
            pasteboardPreview = nil
        }
    }

    private func updateStatus(from result: ClipboardAutoSyncResult, forceSync: Bool) {
        if result.didSaveItem, let item = result.syncedItem {
            statusMessage = result.wasNewContent
                ? "Saved new \(item.kind.displayName.lowercased()) from the current clipboard."
                : "Clipboard is already in history and ready in the keyboard."
            return
        }

        if result.didReadPasteboard {
            statusMessage = "Nothing usable is currently on the iPhone/iPad clipboard."
            return
        }

        statusMessage = forceSync
            ? "Clipboard is already up to date."
            : "Clipboard syncs automatically when this app or keyboard opens."
    }
}
#endif
