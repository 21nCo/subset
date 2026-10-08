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
                Text(timerInterval: Date.now...context.state.endsAt, countsDown: true)
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
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date.now...context.state.endsAt, countsDown: true)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "eyes")
            } compactTrailing: {
                Text(timerInterval: Date.now...context.state.endsAt, countsDown: true)
                    .monospacedDigit()
                    .frame(width: 42)
            } minimal: {
                Image(systemName: "eyes")
            }
        }
    }
}
