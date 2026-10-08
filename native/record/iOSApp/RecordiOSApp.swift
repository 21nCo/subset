import SwiftUI

@main
struct RecordiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = RecordingManager()

    var body: some Scene {
        WindowGroup {
            RecordingDashboardView(
                platformTitle: "Record",
                secondaryNote: "Clips stay on this device. Recording continues when you leave the app, and a Live Activity shows the timer on the Lock Screen and in the Dynamic Island."
            )
            .environmentObject(recorder)
        }
        .onChange(of: scenePhase) { _, newPhase in
            recorder.handleScenePhaseChange(newPhase)
        }
    }
}
