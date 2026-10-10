#if os(iOS)
@preconcurrency import ActivityKit
import Foundation

actor RecordingActivityBridge {
    private var activity: Activity<RecordingActivityAttributes>?
    /// Incremented by every start and end. A start that resumes after an end ran during its
    /// suspension sees a different value and does not request an orphaned activity.
    private var generation = 0

    func cleanupOrphanedActivities() async {
        await endAllActivities(
            startedAt: Date(),
            samples: [],
            title: "Recording complete",
            dismissalPolicy: .immediate
        )
    }

    /// Returns whether a Live Activity is now showing this recording.
    func start(startedAt: Date, samples: [Double]) async -> Bool {
        generation += 1
        let startGeneration = generation
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }

        await endAllActivities(
            startedAt: startedAt,
            samples: samples,
            title: "Recording complete",
            dismissalPolicy: .immediate
        )

        let attributes = RecordingActivityAttributes(sessionID: UUID().uuidString)
        let state = makeState(
            startedAt: startedAt,
            samples: trimmed(samples),
            title: "Recording in progress"
        )

        guard generation == startGeneration else { return false }

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            return true
        } catch {
            print("Live Activity request failed: \(error.localizedDescription)")
            return false
        }
    }

    func update(startedAt: Date, samples: [Double], includeAlert: Bool = false) async {
        guard let activity else { return }
        let content = ActivityContent(
            state: makeState(
                startedAt: startedAt,
                samples: trimmed(samples),
                title: "Recording in progress"
            ),
            staleDate: nil
        )

        if includeAlert {
            let alertConfiguration = AlertConfiguration(
                title: "Recording in progress",
                body: "Record is still recording in the background.",
                sound: .named("silent.caf")
            )
            await activity.update(content, alertConfiguration: alertConfiguration)
        } else {
            await activity.update(content)
        }
    }

    func end(startedAt: Date, samples: [Double]) async {
        generation += 1
        await endAllActivities(
            startedAt: startedAt,
            samples: samples,
            title: "Recording complete",
            dismissalPolicy: .immediate
        )
    }

    private func endAllActivities(
        startedAt: Date,
        samples: [Double],
        title: String,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        let content = ActivityContent(
            state: makeState(
                startedAt: startedAt,
                samples: trimmed(samples),
                title: title
            ),
            staleDate: nil
        )

        for existingActivity in Activity<RecordingActivityAttributes>.activities {
            await existingActivity.end(content, dismissalPolicy: dismissalPolicy)
        }

        activity = nil
    }

    private func trimmed(_ samples: [Double]) -> [Double] {
        Array(samples.suffix(72))
    }

    private func makeState(startedAt: Date, samples: [Double], title: String) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            startedAt: startedAt,
            samples: samples,
            title: title,
            elapsedText: Self.elapsedText(since: startedAt)
        )
    }

    private static func elapsedText(since startedAt: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
#endif
