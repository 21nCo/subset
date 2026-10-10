import SwiftUI

@main
struct BreaksApp: App {
    @StateObject private var engine = BreakEngine()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("onboarding.completed", store: SharedStore.defaults) private var onboardingCompleted = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(BreakPalette.magenta)
                .onAppear(perform: startIfReady)
                .onChange(of: onboardingCompleted) { _, _ in startIfReady() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { startIfReady() }
                }
        }
    }

    /// Breaks start only after onboarding, so a break or heads-up cannot interrupt it.
    private func startIfReady() {
        guard onboardingCompleted else { return }
        engine.start()
        engine.processPendingCommand()
    }
}
