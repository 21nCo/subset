#if canImport(UIKit)
import Foundation
import UIKit

struct ClipboardAutoSyncResult {
    let syncedItem: ClipboardItem?
    let didReadPasteboard: Bool
    let didSaveItem: Bool
    let wasNewContent: Bool
}

@MainActor
final class ClipboardAutoSync {
    private let store: ClipboardHistoryStore
    private let defaults: UserDefaults?
    private let maximumHistoryCount: Int
    private let lastSyncedChangeCountKey = "dev.subset.clipboard.lastSyncedPasteboardChangeCount"

    init(
        store: ClipboardHistoryStore,
        defaults: UserDefaults? = UserDefaults(suiteName: SharedContainer.appGroupIdentifier),
        maximumHistoryCount: Int = 200
    ) {
        self.store = store
        self.defaults = defaults
        self.maximumHistoryCount = maximumHistoryCount
    }

    /// Records the current pasteboard change as already synced. Call right after Clipboard
    /// itself writes to the pasteboard, so its own write is not captured again (re-encoding an
    /// image would otherwise add a duplicate).
    func markCurrentPasteboardSynced() {
        defaults?.set(UIPasteboard.general.changeCount, forKey: lastSyncedChangeCountKey)
    }

    func syncIfNeeded(
        force: Bool = false,
        sourceAppName: String = "System Clipboard"
    ) -> ClipboardAutoSyncResult {
        let pasteboard = UIPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        let lastSyncedChangeCount = defaults?.object(forKey: lastSyncedChangeCountKey) as? Int

        if !force, lastSyncedChangeCount == currentChangeCount {
            return ClipboardAutoSyncResult(
                syncedItem: nil,
                didReadPasteboard: false,
                didSaveItem: false,
                wasNewContent: false
            )
        }

        guard pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages else {
            defaults?.set(currentChangeCount, forKey: lastSyncedChangeCountKey)
            return ClipboardAutoSyncResult(
                syncedItem: nil,
                didReadPasteboard: false,
                didSaveItem: false,
                wasNewContent: false
            )
        }

        // Never read or store content that password managers and other apps mark as
        // concealed or transient (the same rule as the Mac monitor).
        if ClipboardPrivacy.shouldIgnore(typeIdentifiers: pasteboard.types) {
            defaults?.set(currentChangeCount, forKey: lastSyncedChangeCountKey)
            return ClipboardAutoSyncResult(
                syncedItem: nil,
                didReadPasteboard: false,
                didSaveItem: false,
                wasNewContent: false
            )
        }

        guard let item = ClipboardItem.fromPasteboard(pasteboard, sourceAppName: sourceAppName) else {
            defaults?.set(currentChangeCount, forKey: lastSyncedChangeCountKey)
            return ClipboardAutoSyncResult(
                syncedItem: nil,
                didReadPasteboard: true,
                didSaveItem: false,
                wasNewContent: false
            )
        }

        var wasNewContent = true
        var storedItem = item
        let saved = store.update { stored in
            var items = stored.sorted { $0.capturedAt > $1.capturedAt }
            if let existingIndex = items.firstIndex(where: { $0.signature == item.signature }) {
                wasNewContent = false
                // A forced re-read of an unchanged pasteboard keeps the clip where it is; a new
                // copy of the same content moves it to the top.
                if lastSyncedChangeCount == currentChangeCount {
                    storedItem = items[existingIndex]
                    return items
                }
                items.remove(at: existingIndex)
            }
            items.insert(item, at: 0)
            if items.count > maximumHistoryCount {
                items.removeLast(items.count - maximumHistoryCount)
            }
            return items
        }

        // Only a successful write marks this change as synced, so a failed save is retried.
        guard saved != nil else {
            return ClipboardAutoSyncResult(
                syncedItem: nil,
                didReadPasteboard: true,
                didSaveItem: false,
                wasNewContent: false
            )
        }
        defaults?.set(currentChangeCount, forKey: lastSyncedChangeCountKey)

        return ClipboardAutoSyncResult(
            syncedItem: storedItem,
            didReadPasteboard: true,
            didSaveItem: true,
            wasNewContent: wasNewContent
        )
    }
}
#endif
