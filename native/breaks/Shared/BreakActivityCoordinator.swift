import ActivityKit
import Foundation

@MainActor
final class BreakActivityCoordinator {
    private var activity: Activity<BreakActivityAttributes>?

    func start(kind: BreakKind, startedAt: Date, endsAt: Date, message: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await end()

        let attributes = BreakActivityAttributes(startedAt: startedAt, title: kind.title)
        let state = BreakActivityAttributes.ContentState(
            endsAt: endsAt,
            message: message,
            isLongBreak: kind == .long || kind == .planned
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: endsAt),
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    func update(endsAt: Date, message: String, isLongBreak: Bool) async {
        guard let activity else { return }
        let state = BreakActivityAttributes.ContentState(
            endsAt: endsAt,
            message: message,
            isLongBreak: isLongBreak
        )
        await activity.update(ActivityContent(state: state, staleDate: endsAt))
    }

    func end() async {
        for active in Activity<BreakActivityAttributes>.activities {
            let final = BreakActivityAttributes.ContentState(
                endsAt: .now,
                message: "Break complete",
                isLongBreak: false
            )
            await active.end(ActivityContent(state: final, staleDate: .now), dismissalPolicy: .immediate)
        }
        activity = nil
    }
}
