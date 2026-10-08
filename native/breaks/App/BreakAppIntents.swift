import AppIntents
import Foundation

struct StartMindfulBreakIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Mindful Break"
    static let description = IntentDescription("Starts a screen-free break immediately.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        BreakRepository().setCommand("start")
        return .result(dialog: "Starting your break.")
    }
}

struct PauseBreakRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Break Reminders"
    static let description = IntentDescription("Pauses the current focus timer.")

    func perform() async throws -> some IntentResult {
        BreakRepository().setCommand("pause")
        return .result()
    }
}

struct ResumeBreakRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Break Reminders"
    static let description = IntentDescription("Resumes the current focus timer.")

    func perform() async throws -> some IntentResult {
        BreakRepository().setCommand("resume")
        return .result()
    }
}

struct BreakFocusFilterIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Breaks Focus Filter"
    static let description = IntentDescription("Pause break reminders while this Focus is active.")

    @Parameter(title: "Pause reminders")
    var isEnabled: Bool?

    init() {
        isEnabled = true
    }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: (isEnabled ?? true) ? "Pause reminders" : "Keep reminders active")
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [BreakFocusFilterIntent] {
        [BreakFocusFilterIntent(isEnabled: true)]
    }

    func perform() async throws -> some IntentResult {
        BreakRepository().setCommand((isEnabled ?? true) ? "focus:on" : "focus:off")
        return .result()
    }
}

struct BreakReminderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMindfulBreakIntent(),
            phrases: ["Start a break with \(.applicationName)", "Rest my eyes with \(.applicationName)"],
            shortTitle: "Start break",
            systemImageName: "eyes"
        )
        AppShortcut(
            intent: PauseBreakRemindersIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause reminders",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeBreakRemindersIntent(),
            phrases: ["Resume \(.applicationName)"],
            shortTitle: "Resume reminders",
            systemImageName: "play.fill"
        )
    }
}
