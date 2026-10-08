import SwiftUI

@main
struct BreaksApp: App {
    @StateObject private var engine = BreakEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(BreakPalette.magenta)
                .onAppear { engine.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        engine.start()
                        engine.processPendingCommand()
                    }
                }
        }
    }
}
