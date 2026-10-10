import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var engine: BreakEngine
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            AmbientBackground(style: .aurora)
            ScrollView {
                VStack(spacing: 18) {
                    daySelector
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 18) {
                            scorePanel.frame(maxWidth: .infinity)
                            metricPanels.frame(maxWidth: .infinity)
                        }
                    } else {
                        scorePanel
                        metricPanels
                    }
                    rhythmPanel
                }
                .frame(maxWidth: 920)
                .padding()
            }
        }
        .navigationTitle("Stats")
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var daySelector: some View {
        // Only today is shown; there is no history browser yet, so there are no day arrows.
        VStack(spacing: 2) {
            Text("Today's Screen Score").font(.headline)
            Text(Date.now, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .glassCard(padding: 12)
    }

    private var scorePanel: some View {
        VStack(spacing: 16) {
            ScoreRing(score: engine.dashboardStats.screenScore, size: 210)
            Text(scoreMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Divider().overlay(.white.opacity(0.08))
            MetricRow(icon: "eyes", color: BreakPalette.magenta, title: "Breaks completed", value: "\(engine.dashboardStats.breaksTaken)")
            MetricRow(icon: "forward.end.fill", color: BreakPalette.coral, title: "Breaks skipped", value: "\(engine.dashboardStats.skippedBreaks)")
            MetricRow(icon: "zzz", color: BreakPalette.violet, title: "Snoozes", value: "\(engine.dashboardStats.snoozes)")
        }
        .glassCard(padding: 22)
    }

    private var metricPanels: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 15) {
                Label("Screen Time Stats", systemImage: "bolt.fill")
                    .font(.headline).foregroundStyle(BreakPalette.amber)
                MetricValueRow(label: "Focused screen time", value: engine.dashboardStats.focusTime.compactDuration)
                MetricValueRow(label: "Longest stretch", value: engine.dashboardStats.longestStretch.compactDuration)
                MetricValueRow(label: "Typical stretch", value: engine.dashboardStats.typicalStretch.compactDuration)
            }
            .glassCard()
            VStack(alignment: .leading, spacing: 15) {
                Label("Break Stats", systemImage: "leaf.fill")
                    .font(.headline).foregroundStyle(BreakPalette.teal)
                MetricValueRow(label: "Total break time", value: engine.dashboardStats.breakTime.compactDuration)
                MetricValueRow(label: "Short breaks", value: "\(todayRecords.filter { $0.kind == .short && $0.completed }.count)")
                MetricValueRow(label: "Long & planned", value: "\(todayRecords.filter { ($0.kind == .long || $0.kind == .planned) && $0.completed }.count)")
            }
            .glassCard()
        }
    }

    private var rhythmPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today's rhythm").font(.headline)
                    Text("Completed and skipped pauses").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset today", role: .destructive) { engine.resetToday() }
                    .font(.caption)
            }
            if todayRecords.isEmpty {
                Text("Your first completed break will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(todayRecords.suffix(8).reversed()) { record in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(record.skipped ? BreakPalette.coral : BreakPalette.magenta)
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.skipped ? "Skipped \(record.kind.title.lowercased())" : record.kind.title)
                            Text(record.startedAt, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.actualDuration.compactDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .glassCard()
    }

    private var todayRecords: [BreakRecord] {
        let start = Calendar.current.startOfDay(for: .now)
        return engine.records.filter { $0.startedAt >= start }
    }

    private var scoreMessage: String {
        switch engine.dashboardStats.screenScore {
        case 90...: "Excellent pacing today with healthy work and rest cycles."
        case 75..<90: "You're building a healthy rhythm. Protect the next break."
        case 50..<75: "A couple of consistent breaks will lift your day."
        default: "Start again gently. One good break is enough to reset the pattern."
        }
    }
}

private struct MetricValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
    }
}
