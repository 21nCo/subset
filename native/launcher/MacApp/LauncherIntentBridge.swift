import AppIntents
import AppKit

@MainActor
final class LauncherIntentBridge {
    static let shared = LauncherIntentBridge()

    var openSearch: ((SearchFilter) -> Void)?
    var openQuickNotes: (() -> Void)?
    var openQuickNoteComposer: (() -> Void)?
    var setAvatarVisible: ((Bool) -> Void)?
    var quickNotesChanged: (() -> Void)?

    private init() {}

    func showSearch(filter: SearchFilter = .all) {
        NSApp.activate()
        openSearch?(filter)
    }

    func showQuickNotes() {
        NSApp.activate()
        openQuickNotes?()
    }

    func showQuickNoteComposer() {
        NSApp.activate()
        openQuickNoteComposer?()
    }

    func notifyQuickNotesChanged() {
        quickNotesChanged?()
    }

    func updateAvatarVisibility(isVisible: Bool) {
        setAvatarVisible?(isVisible)
    }
}

struct OpenLauncherIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Launcher"
    static let description = IntentDescription("Open the Launcher search panel.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await LauncherIntentBridge.shared.showSearch()
        return .result()
    }
}

struct OpenEmojiPickerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Emoji Picker"
    static let description = IntentDescription("Open Launcher directly in emoji picker mode.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await LauncherIntentBridge.shared.showSearch(filter: .emoji)
        return .result()
    }
}

struct OpenCalculatorIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Calculator"
    static let description = IntentDescription("Open Launcher directly in calculator mode.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await LauncherIntentBridge.shared.showSearch(filter: .calculator)
        return .result()
    }
}

struct OpenQuickNoteComposerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Note"
    static let description = IntentDescription("Open the Launcher quick note composer.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await LauncherIntentBridge.shared.showQuickNoteComposer()
        return .result()
    }
}

struct CreateQuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Quick Note"
    static let description = IntentDescription("Create and save a quick note in Launcher.")
    static let openAppWhenRun = false

    @Parameter(title: "Title")
    var titleText: String

    @Parameter(title: "Details")
    var details: String

    func perform() async throws -> some IntentResult {
        guard !PersistenceController.isBlankNote(title: titleText, body: details) else {
            throw LauncherIntentError.emptyNote
        }
        if case .failure(let error) = await PersistenceController.shared.saveQuickNote(title: titleText, body: details) {
            throw error
        }
        // Keep an open Quick Notes window in sync with the store.
        await LauncherIntentBridge.shared.notifyQuickNotesChanged()
        return .result()
    }
}

enum LauncherIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyNote

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyNote:
            return "Enter a title or details before saving a note."
        }
    }
}

struct OpenQuickNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Notes"
    static let description = IntentDescription("Open the saved quick notes window.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await LauncherIntentBridge.shared.showQuickNotes()
        return .result()
    }
}

struct ShowAvatarIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Floating Button"
    static let description = IntentDescription("Show the floating Launcher button.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await LauncherIntentBridge.shared.updateAvatarVisibility(isVisible: true)
        return .result()
    }
}

struct HideAvatarIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide Floating Button"
    static let description = IntentDescription("Hide the floating Launcher button.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await LauncherIntentBridge.shared.updateAvatarVisibility(isVisible: false)
        return .result()
    }
}

struct LauncherAppShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLauncherIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Search with \(.applicationName)"
            ],
            shortTitle: "Open Launcher",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: OpenEmojiPickerIntent(),
            phrases: [
                "Open emoji picker in \(.applicationName)",
                "Search emoji with \(.applicationName)"
            ],
            shortTitle: "Emoji Picker",
            systemImageName: "face.smiling"
        )

        AppShortcut(
            intent: OpenCalculatorIntent(),
            phrases: [
                "Open calculator in \(.applicationName)",
                "Calculate with \(.applicationName)"
            ],
            shortTitle: "Calculator",
            systemImageName: "plus.forwardslash.minus"
        )

        AppShortcut(
            intent: OpenQuickNoteComposerIntent(),
            phrases: [
                "Open quick note in \(.applicationName)",
                "Capture note with \(.applicationName)"
            ],
            shortTitle: "Quick Note",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: OpenQuickNotesIntent(),
            phrases: [
                "Open notes in \(.applicationName)",
                "Show quick notes in \(.applicationName)"
            ],
            shortTitle: "Notes",
            systemImageName: "note.text"
        )
    }
}
