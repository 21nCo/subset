import Combine
import SwiftUI

@MainActor
final class DictationAppController: ObservableObject {
    let manager: DictationManager

    private let panelController = FloatingActivationPanelController.shared
    private let hotkeyMonitor = GlobalHotkeyMonitor.shared
    private var cancellables = Set<AnyCancellable>()
    /// Whether the current fn press started a session. Only that press's release inserts,
    /// so a press during finalization or during a window-started session does nothing.
    private var pressStartedSession = false

    init(manager: DictationManager = DictationManager()) {
        self.manager = manager
        startHotkeyMonitoring()
        observeRecordingState()
    }

    deinit {
        Task { @MainActor in
            GlobalHotkeyMonitor.shared.stop()
            FloatingActivationPanelController.shared.hide()
        }
    }

    private func startHotkeyMonitoring() {
        hotkeyMonitor.start(
            onPress: { [weak self] in
                guard let self else { return }
                // Capture the insertion target only for a new session; a press while the
                // previous one finalizes must not redirect its pending insertion.
                guard !manager.isBusy else {
                    pressStartedSession = false
                    return
                }
                pressStartedSession = true
                manager.rememberInsertionTarget()
                manager.clearTranscript()
                manager.startDictation()
            },
            onRelease: { [weak self] in
                guard let self, pressStartedSession else { return }
                pressStartedSession = false
                manager.stopDictationAndInsert()
            },
            onCancel: { [weak self] in
                guard let self, pressStartedSession else { return }
                // Esc and the following fn release both cancel; only the first may act, so a
                // session started from the window in between is not cancelled.
                pressStartedSession = false
                manager.cancelDictation()
            }
        )
    }

    private func observeRecordingState() {
        manager.$transcriptState
            .map(\.isRecording)
            .removeDuplicates()
            .sink { [weak self] isRecording in
                guard let self else { return }
                if isRecording {
                    panelController.showForSession(manager: manager)
                } else {
                    panelController.endSessionVisibility()
                }
            }
            .store(in: &cancellables)
    }
}
