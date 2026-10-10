import ActivityKit
import SwiftUI
import WidgetKit

struct BreakLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BreakActivityAttributes.self) { context in
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.13))
                    Image(systemName: "eyes")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title)
                        .font(.headline)
                    Text(context.state.message)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                Spacer()
                BreakCountdown(context: context)
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding()
            .activityBackgroundTint(Color(red: 0.12, green: 0.08, blue: 0.18))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "eyes")
                        .accessibilityLabel("Break")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BreakCountdown(context: context)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "eyes")
                    .accessibilityLabel("Break")
            } compactTrailing: {
                BreakCountdown(context: context)
                    .monospacedDigit()
                    .frame(width: 42)
            } minimal: {
                Image(systemName: "eyes")
                    .accessibilityLabel("Break")
            }
        }
    }
}

/// Counts down to the break's end. The range starts at the break's start, so it stays valid (lower bound not
/// after upper bound) after the end has passed, and an ended or stale activity shows that it is done.
private struct BreakCountdown: View {
    let context: ActivityViewContext<BreakActivityAttributes>

    var body: some View {
        let start = context.attributes.startedAt
        let end = max(start, context.state.endsAt)
        if context.isStale || end <= .now {
            Text("Done")
        } else {
            Text(timerInterval: start...end, countsDown: true)
        }
    }
}
