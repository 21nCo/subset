#if canImport(UIKit)
import Foundation
import UIKit

@MainActor
final class KeyboardClipboardController: ObservableObject {
    @Published private(set) var items: [ClipboardItem]
    @Published private(set) var statusMessage = "Tap a card to paste."
    @Published private(set) var hasFullAccess = false

    private let store: ClipboardHistoryStore
    private let autoSync: ClipboardAutoSync

    init(
        store: ClipboardHistoryStore = ClipboardHistoryStore(
            appGroupIdentifier: SharedContainer.appGroupIdentifier,
            namespace: SharedContainer.historyNamespace
        )
    ) {
        self.store = store
        self.autoSync = ClipboardAutoSync(store: store)
        self.items = store.load().sorted { $0.capturedAt > $1.capturedAt }
    }

    var subtitle: String {
        items.isEmpty ? "Copy something, then open the keyboard" : "\(items.count) saved clips"
    }

    func reload(forceSync: Bool = false) {
        let syncResult = autoSync.syncIfNeeded(force: forceSync)
        items = store.load().sorted { $0.capturedAt > $1.capturedAt }

        if syncResult.didSaveItem, let item = syncResult.syncedItem {
            statusMessage = syncResult.wasNewContent
                ? "Saved new \(item.kind.displayName.lowercased()) from the clipboard."
                : "Clipboard is already in history."
            return
        }

        if syncResult.didReadPasteboard {
            statusMessage = "The current clipboard content is not supported yet."
            return
        }

        statusMessage = items.isEmpty
            ? "Copy something, then open this keyboard again."
            : "Tap a text or link card to paste."
    }

    func updateSetupState(fullAccess: Bool) {
        hasFullAccess = fullAccess
        KeyboardSetupState.noteKeyboardPresentation(fullAccess: fullAccess)
    }

    func showSettingsGuidance(openAttemptSucceeded: Bool) {
        statusMessage = openAttemptSucceeded
            ? "Opening Keyboard settings. Enable Full Access for Clipboard Keyboard there."
            : "Open Settings > General > Keyboard > Keyboards > Clipboard Keyboard and enable Full Access."
    }

    func activate(_ item: ClipboardItem, insertText: (String) -> Void) {
        switch item.kind {
        case .text, .url:
            guard let textContent = item.textContent else {
                statusMessage = "This card does not contain text yet."
                return
            }

            insertText(textContent)
            statusMessage = "Inserted \(item.kind.displayName.lowercased())."

        case .image:
            if item.write(to: UIPasteboard.general) {
                statusMessage = "Photo copied. Long-press the field and tap Paste."
            } else {
                statusMessage = "Could not copy that photo."
            }

        case .files:
            if item.write(to: UIPasteboard.general) {
                statusMessage = "File copied. Use Paste if the current app supports files."
            } else {
                statusMessage = "Could not restore that file."
            }
        }
    }
}
#endif
