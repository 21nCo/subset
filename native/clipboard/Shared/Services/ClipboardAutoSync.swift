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

        guard let item = ClipboardItem.fromPasteboard(pasteboard, sourceAppName: sourceAppName) else {
            defaults?.set(currentChangeCount, forKey: lastSyncedChangeCountKey)
            return ClipboardAutoSyncResult(
                syncedItem: nil,
                didReadPasteboard: true,
                didSaveItem: false,
                wasNewContent: false
            )
        }

        var items = store.load().sorted { $0.capturedAt > $1.capturedAt }
        let existingIndex = items.firstIndex { $0.signature == item.signature }
        let wasNewContent = existingIndex == nil

        if let existingIndex {
            items.remove(at: existingIndex)
        }

        items.insert(item, at: 0)

        if items.count > maximumHistoryCount {
            items.removeLast(items.count - maximumHistoryCount)
        }

        store.save(items)
        defaults?.set(currentChangeCount, forKey: lastSyncedChangeCountKey)

        return ClipboardAutoSyncResult(
            syncedItem: item,
            didReadPasteboard: true,
            didSaveItem: true,
            wasNewContent: wasNewContent
        )
    }
}
#endif
