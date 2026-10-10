import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var engine: BreakEngine
    @Binding var isCompleted: Bool
    @State private var page = 0
    @State private var isRequestingPermissions = false

    var body: some View {
        ZStack {
            AmbientBackground(style: .dusk)
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    rhythm.tag(1)
                    permissions.tag(2)
                    ready.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                HStack(spacing: 12) {
                    if page > 0 {
                        Button("Back") {
                            withAnimation { page -= 1 }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(page == 3 ? "Start caring for my eyes" : "Continue") {
                        if page == 3 {
                            isCompleted = true
                        } else {
                            withAnimation { page += 1 }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
    }

    private var welcome: some View {
        OnboardingPage(
            visual: AnyView(RestMark(size: 112)),
            eyebrow: "A kinder screen rhythm",
            title: "Your body will thank you",
            message: "Gentle, well-timed breaks help your eyes, posture, and attention recover without breaking your flow."
        )
    }

    private var rhythm: some View {
        OnboardingPage(
            visual: AnyView(
                ZStack {
                    Circle().stroke(.white.opacity(0.14), lineWidth: 14)
                    Circle().trim(from: 0, to: 0.72).stroke(BreakPalette.accentGradient, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack { Text("20:00").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit(); Text("focus").foregroundStyle(.secondary) }
                }.frame(width: 160, height: 160)
            ),
            eyebrow: "Breaks that respect your focus",
            title: "Work. Pause. Return refreshed.",
            message: "Start with the 20–20–20 rhythm, then tune intervals, long breaks, office hours, and discipline to fit your day."
        )
    }

    private var permissions: some View {
        ScrollingPage {
            VStack(spacing: 26) {
                Spacer()
                HStack(spacing: 18) {
                    PermissionGlyph(icon: "bell.badge.fill", color: BreakPalette.coral)
                    PermissionGlyph(icon: "hourglass.badge.plus", color: BreakPalette.magenta)
                    PermissionGlyph(icon: "lock.shield.fill", color: BreakPalette.violet)
                }
                VStack(spacing: 12) {
                    Text("Make breaks work everywhere")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text("Notifications give you a gentle heads-up. Screen Time can shield distracting apps and sites while a break is active.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                Button {
                    isRequestingPermissions = true
                    Task {
                        await engine.requestSetupPermissions()
                        isRequestingPermissions = false
                    }
                } label: {
                    HStack {
                        if isRequestingPermissions { ProgressView() }
                        Text(isRequestingPermissions ? "Requesting…" : "Enable notifications & Screen Time")
                    }
                    .frame(maxWidth: 420)
                }
                .buttonStyle(.borderedProminent)
                .tint(BreakPalette.magenta)
                .controlSize(.large)
                .disabled(isRequestingPermissions)
                Text("You can change either permission later in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(32)
        }
    }

    private var ready: some View {
        OnboardingPage(
            visual: AnyView(
                Image(systemName: "checkmark")
                    .font(.system(size: 54, weight: .bold))
                    .frame(width: 116, height: 116)
                    .background(BreakPalette.accentGradient, in: Circle())
            ),
            eyebrow: "You're ready",
            title: "First break in 20 minutes",
            message: "We'll give you a quiet heads-up before it begins. You can start, pause, or fine-tune everything at any time."
        )
    }
}

private struct OnboardingPage: View {
    let visual: AnyView
    let eyebrow: String
    let title: String
    let message: String

    var body: some View {
        ScrollingPage {
            VStack(spacing: 28) {
                Spacer()
                visual
                VStack(spacing: 14) {
                    Text(eyebrow.uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.8)
                        .foregroundStyle(BreakPalette.amber)
                    Text(title)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.76)
                    Text(message)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 580)
                }
                Spacer()
            }
            .padding(30)
        }
    }
}

/// Fills the page when there is room and scrolls when there is not (landscape, large text).
private struct ScrollingPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content.frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct PermissionGlyph: View {
    let icon: String
    let color: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 30, weight: .semibold))
            .frame(width: 72, height: 72)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: color.opacity(0.3), radius: 18, y: 8)
            .accessibilityHidden(true)
    }
}
