import AppKit
import SwiftUI

struct MacRootView: View {
    @EnvironmentObject private var recorder: RecordingManager
    private let floatingPanelController = FloatingRecorderPanelController.shared

    var body: some View {
        RecordingDashboardView(
            platformTitle: "Record",
            secondaryNote: "Clips are saved as M4A files in ~/Documents/Subset Record. While recording, a small panel stays on top of other windows so you can see the timer and stop from anywhere."
        )
        .onAppear {
            floatingPanelController.bind(to: recorder)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The recordings folder is the source of truth; pick up clips added or removed in Finder.
            if !recorder.isRecording {
                recorder.reloadSavedRecordings()
            }
        }
    }
}
