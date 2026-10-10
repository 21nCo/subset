import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var engine: BreakEngine
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            AmbientBackground(style: .aurora)
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 18) {
                            nowCard.frame(maxWidth: .infinity)
                            scoreCard.frame(maxWidth: .infinity)
                        }
                    } else {
                        nowCard
                        scoreCard
                    }
                    quickMetrics
                    upcomingPlannedBreak
                }
                .frame(maxWidth: 980)
                .padding()
            }
        }
        .navigationTitle("Now")
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RestMark(size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.title2.weight(.bold))
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                engine.phase == .paused ? engine.resume() : engine.pause()
            } label: {
                Label(engine.phase == .paused ? "Resume" : "Pause", systemImage: engine.phase == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .accessibilityHint(engine.phase == .paused ? "Restarts break reminders" : "Stops break reminders until you resume")
        }
        .padding(.vertical, 4)
    }

    private var nowCard: some View {
        VStack(spacing: 18) {
            Image(systemName: engine.phase == .paused ? "pause.fill" : "hourglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(engine.phase == .paused ? "Timer paused" : "Break starts in")
                    .foregroundStyle(.secondary)
                Text(engine.nextBreakRemaining.clockDuration)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(engine.phase == .paused ? "Timer paused" : "Break starts in \(engine.nextBreakRemaining.spokenDuration)")
            .accessibilityAddTraits(.updatesFrequently)
            ProgressView(value: min(1, engine.focusElapsed / engine.settings.workInterval))
                .tint(BreakPalette.amber)
                .accessibilityLabel("Focus interval progress")

            // On narrow phones the snooze buttons move to their own row instead of being cut off.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    startBreakButton
                    SnoozeButtons(engine: engine)
                }
                VStack(spacing: 8) {
                    startBreakButton
                    HStack(spacing: 8) { SnoozeButtons(engine: engine) }
                }
            }
            .controlSize(.regular)

            SnoozeAllowanceNote(remaining: engine.snoozesRemaining, allowed: engine.settings.snoozesAllowedPerDay)
        }
        .frame(maxWidth: .infinity)
        .glassCard(padding: 22)
    }

    private var startBreakButton: some View {
        Button("Start break") { engine.startBreak(kind: .manual) }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .keyboardShortcut("b", modifiers: .command)
    }

    private var scoreCard: some View {
        VStack(spacing: 12) {
            ScoreRing(score: engine.dashboardStats.screenScore, size: 174)
            Text(scoreMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .glassCard(padding: 22)
    }

    private var quickMetrics: some View {
        VStack(spacing: 14) {
            MetricRow(icon: "bolt.fill", color: BreakPalette.amber, title: "Current focus time", value: engine.focusElapsed.compactDuration)
            Divider().overlay(.white.opacity(0.08))
            MetricRow(icon: "eyes", color: BreakPalette.magenta, title: "Upcoming break", value: "\(nextKindTitle) · \(nextBreakDuration.compactDuration)")
            Divider().overlay(.white.opacity(0.08))
            MetricRow(icon: "zzz", color: BreakPalette.violet, title: "Snoozes available", value: "\(engine.snoozesRemaining)")
        }
        .glassCard()
    }

    @ViewBuilder
    private var upcomingPlannedBreak: some View {
        if let (planned, date) = engine.nextPlannedBreak {
            HStack(spacing: 14) {
                Image(systemName: planned.symbol)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(BreakPalette.coral.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next planned break")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(planned.name)
                        .font(.headline)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(date, style: .time).fontWeight(.semibold)
                    Text(planned.duration.compactDuration).font(.caption).foregroundStyle(.secondary)
                }
            }
            .glassCard()
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: engine.now)
        return hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    }

    private var statusLine: String {
        switch engine.phase {
        case .focusing: "Your focus timer is running quietly."
        case .headsUp: "A break is almost here."
        case .breaking: "Your break is active."
        case .paused: "Reminders are waiting for you."
        }
    }

    private var nextKindTitle: String {
        engine.upcomingBreakKind == .long ? "Long" : "Short"
    }

    private var nextBreakDuration: TimeInterval {
        nextKindTitle == "Long" ? engine.settings.longBreakDuration : engine.settings.shortBreakDuration
    }

    private var scoreMessage: String {
        switch engine.dashboardStats.screenScore {
        case 90...: "Excellent pacing today with healthy work and rest cycles."
        case 75..<90: "A steady day. Take the next break to keep your rhythm."
        default: "Your body could use a reset. Start a mindful break now."
        }
    }
}

struct HeadsUpView: View {
    @EnvironmentObject private var engine: BreakEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(.secondary.opacity(0.4)).frame(width: 42, height: 5)
            RestMark(size: 62)
            VStack(spacing: 6) {
                Text(engine.nextBreakRemaining.clockDuration)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Almost time. Your eyes will appreciate this.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    startNowButton
                    SnoozeButtons(engine: engine) { dismiss() }
                }
                VStack(spacing: 8) {
                    startNowButton
                    HStack(spacing: 8) { SnoozeButtons(engine: engine) { dismiss() } }
                }
            }
            SnoozeAllowanceNote(remaining: engine.snoozesRemaining, allowed: engine.settings.snoozesAllowedPerDay)
        }
        .padding(24)
    }

    private var startNowButton: some View {
        Button("Start now") {
            dismiss()
            engine.startBreak(kind: engine.upcomingBreakKind)
        }
        .buttonStyle(.borderedProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .keyboardShortcut(.defaultAction)
    }
}

/// Snooze choices shared by the dashboard and the heads-up sheet.
/// ⌘1, ⌘5, and ⌘0 snooze for 1, 5, and 15 minutes from a hardware keyboard.
struct SnoozeButtons: View {
    @ObservedObject var engine: BreakEngine
    var afterSnooze: () -> Void = {}

    private let options: [(minutes: Int, key: KeyEquivalent)] = [(1, "1"), (5, "5"), (15, "0")]

    var body: some View {
        ForEach(options, id: \.minutes) { option in
            Button("+\(option.minutes)m") {
                engine.snooze(minutes: option.minutes)
                afterSnooze()
            }
            .buttonStyle(.bordered)
            .disabled(engine.snoozesRemaining == 0)
            .keyboardShortcut(option.key, modifiers: .command)
            .accessibilityLabel("Snooze \(option.minutes) \(option.minutes == 1 ? "minute" : "minutes")")
            .accessibilityHint(engine.snoozesRemaining == 0 ? "No snoozes left today" : "\(engine.snoozesRemaining) snoozes left today")
        }
    }
}

/// Explains the daily snooze limit instead of silently disabling the snooze buttons.
struct SnoozeAllowanceNote: View {
    let remaining: Int
    let allowed: Int

    var body: some View {
        Group {
            if allowed == 0 {
                Text("Snoozing is turned off. You can allow snoozes in Settings.")
            } else if remaining == 0 {
                Text("You've used all \(allowed) snoozes today. They reset tomorrow, or you can raise the limit in Settings.")
            } else {
                Text("\(remaining) of \(allowed) snoozes left today")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}
