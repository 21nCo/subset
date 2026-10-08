import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case now
    case breaks
    case stats
    case settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .now: "hourglass"
        case .breaks: "eyes"
        case .stats: "chart.bar.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var engine: BreakEngine
    @AppStorage("onboarding.completed", store: SharedStore.defaults) private var onboardingCompleted = false
    @State private var selectedSection: AppSection = .now
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if onboardingCompleted {
                adaptiveNavigation
            } else {
                OnboardingView(isCompleted: $onboardingCompleted)
            }
        }
        .fullScreenCover(isPresented: $engine.isBreakPresented) {
            BreakExperienceView()
                .environmentObject(engine)
        }
        .sheet(isPresented: $engine.isHeadsUpPresented) {
            HeadsUpView()
                .environmentObject(engine)
                .presentationDetents([.height(330)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .overlay(alignment: countdownAlignment) {
            if onboardingCompleted,
               engine.settings.reminder.countdownEnabled,
               engine.phase != .breaking,
               engine.phase != .paused,
               engine.nextBreakRemaining > 0,
               engine.nextBreakRemaining <= engine.settings.reminder.countdownDuration {
                FloatingCountdownView(seconds: Int(engine.nextBreakRemaining.rounded(.up)))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: engine.nextBreakRemaining <= engine.settings.reminder.countdownDuration)
    }

    private var countdownAlignment: Alignment {
        switch engine.settings.reminder.position {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        }
    }

    @ViewBuilder
    private var adaptiveNavigation: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                List {
                    ForEach(AppSection.allCases) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selectedSection == section ? BreakPalette.magenta.opacity(0.18) : Color.clear)
                    }
                }
                .navigationTitle("Breaks")
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 10) {
                        RestMark(size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(engine.phase == .paused ? "Paused" : "Running")
                                .font(.caption.weight(.semibold))
                            Text(engine.phase == .breaking ? "Break in progress" : "Next in \(engine.nextBreakRemaining.compactDuration)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                }
            } detail: {
                sectionView(selectedSection)
            }
        } else {
            TabView(selection: $selectedSection) {
                ForEach(AppSection.allCases) { section in
                    NavigationStack {
                        sectionView(section)
                    }
                    .tabItem { Label(section.title, systemImage: section.symbol) }
                    .tag(section)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: AppSection) -> some View {
        switch section {
        case .now: DashboardView()
        case .breaks: BreaksView()
        case .stats: StatsView()
        case .settings: SettingsView()
        }
    }
}

private struct FloatingCountdownView: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 10) {
            SettingsGlyph(icon: "eyes", color: BreakPalette.magenta)
            VStack(alignment: .leading, spacing: 1) {
                Text("Starting break in \(seconds)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("Find a natural stopping point")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard(padding: 10)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityLabel("Starting break in \(seconds) seconds")
    }
}
