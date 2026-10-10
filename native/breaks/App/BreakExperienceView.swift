import SwiftUI

struct BreakExperienceView: View {
    @EnvironmentObject private var engine: BreakEngine
    @State private var skipAttempted = false

    var body: some View {
        ZStack {
            AmbientBackground(
                style: engine.settings.customization.background,
                showArtwork: true,
                customFilename: engine.settings.customization.customBackgroundFilename
            )
            VStack(spacing: 0) {
                topBar
                Spacer()
                VStack(spacing: 22) {
                    RestMark(size: 84)
                    VStack(spacing: 8) {
                        Text(engine.snapshot.activePlannedBreakName ?? engine.snapshot.activeKind?.title ?? "Mindful break")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.74))
                        Text(engine.breakRemaining.clockDuration)
                            .font(.system(size: 82, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .minimumScaleFactor(0.72)
                            .accessibilityLabel("\(engine.breakRemaining.spokenDuration) left in this break")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Text(engine.activeMessage)
                        .font(.system(.title2, design: .rounded, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: 560)
                }
                .padding(.horizontal, 30)
                Spacer()
                controls
            }
            .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled()
    }

    private var topBar: some View {
        HStack {
            Label("Screen-free break", systemImage: "eyes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
            if engine.screenTime.shieldsSomething(settings: engine.settings) {
                Label("Distractions shielded", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            ProgressView(value: engine.breakProgress)
                .tint(.white)
                .frame(maxWidth: 520)
            if engine.canEndEarly {
                Button("End break") { engine.endBreak(completed: true) }
                    .buttonStyle(BreakPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else if engine.settings.discipline != .hardcore {
                Button {
                    if !engine.skipActiveBreak() { skipAttempted = true }
                } label: {
                    HStack {
                        Image(systemName: engine.canSkipBreak ? "forward.end.fill" : "timer")
                        Text(skipButtonTitle)
                    }
                }
                .buttonStyle(BreakSecondaryButtonStyle())
                .sensoryFeedback(.warning, trigger: skipAttempted)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint(engine.canSkipBreak ? "Ends this break early and records it as skipped" : "Skipping becomes available after a few seconds")
            } else {
                Label("This break can't be skipped", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.66))
                    .padding(.bottom, 16)
            }
            Text("Look at something at least 20 feet away and let your focus soften.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var skipButtonTitle: String {
        guard engine.settings.discipline == .balanced, !engine.canSkipBreak else { return "Skip break" }
        let elapsed = engine.now.timeIntervalSince(engine.snapshot.breakStartedAt ?? engine.now)
        return "Skip available in \(max(1, Int(BreakScheduler.balancedSkipDelay) - Int(elapsed)))s"
    }
}

private struct BreakPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: 520)
            .padding(.vertical, 16)
            .background(.white.opacity(configuration.isPressed ? 0.78 : 0.96), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct BreakSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white.opacity(0.82))
            .frame(maxWidth: 520)
            .padding(.vertical, 15)
            .background(.ultraThinMaterial.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14)))
    }
}
