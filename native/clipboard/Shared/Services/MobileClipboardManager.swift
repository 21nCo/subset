#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class MobileClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipboardItem]
    @Published private(set) var pasteboardPreview: ClipboardItem?
    @Published var draftText = ""
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
        self.pasteboardPreview = items.first
        registerAutomaticSyncObservers()
        refresh(forceSync: true)
    }

    var keyboardSubtitle: String {
        items.isEmpty ? "Copy something, then open the keyboard" : "\(items.count) ready for the keyboard"
    }

    func refresh(forceSync: Bool = false) {
        let syncResult = autoSync.syncIfNeeded(force: forceSync)
        reloadItems(preferredPreview: syncResult.syncedItem)
        updateStatus(from: syncResult, forceSync: forceSync)
    }

    func syncCurrentClipboardNow() {
        refresh(forceSync: true)
    }

    func clearHistory() {
        items.removeAll(keepingCapacity: false)
        store.save(items)
        pasteboardPreview = nil
        statusMessage = "Cleared the shared iPhone/iPad clipboard history."
    }

    func applySelectionToDraft(_ item: ClipboardItem) {
        switch item.kind {
        case .text, .url:
            guard let textContent = item.textContent else {
                statusMessage = "This card does not contain text yet."
                return
            }

            if draftText.isEmpty {
                draftText = textContent
            } else {
                draftText += draftText.hasSuffix(" ") ? textContent : " \(textContent)"
            }

            statusMessage = "Inserted \(item.kind.displayName.lowercased()) into the composer preview."

        case .image, .files:
            if item.write(to: UIPasteboard.general) {
                statusMessage = item.kind == .image
                    ? "Photo copied to the clipboard."
                    : "File copied to the clipboard."
            } else {
                statusMessage = "Could not restore that \(item.kind.displayName.lowercased()) to the clipboard."
            }
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
                    self?.refresh(forceSync: true)
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

    private func reloadItems(preferredPreview: ClipboardItem? = nil) {
        items = store.load().sorted { $0.capturedAt > $1.capturedAt }
        pasteboardPreview = preferredPreview ?? items.first
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
