import SwiftUI

struct MacRootView: View {
    @EnvironmentObject private var recorder: RecordingManager
    private let floatingPanelController = FloatingRecorderPanelController.shared

    var body: some View {
        RecordingDashboardView(
            platformTitle: "Record",
            secondaryNote: "Clips are saved as M4A files in ~/Documents/Subset Record. While recording, a small panel stays on top of other windows so you can see the timer and stop from anywhere."
        )
        .onChange(of: recorder.isRecording, initial: true) { _, isRecording in
            if isRecording {
                floatingPanelController.show(recorder: recorder)
            } else {
                floatingPanelController.hide()
            }
        }
    }
}
