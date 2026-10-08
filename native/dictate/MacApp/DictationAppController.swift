import Combine
import SwiftUI

@MainActor
final class DictationAppController: ObservableObject {
    let manager: DictationManager

    private let panelController = FloatingActivationPanelController.shared
    private let hotkeyMonitor = GlobalHotkeyMonitor.shared
    private var cancellables = Set<AnyCancellable>()

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
                manager.rememberInsertionTarget()
                if !manager.transcriptState.isRecording {
                    manager.clearTranscript()
                    manager.startDictation()
                }
            },
            onRelease: { [weak self] in
                guard let self else { return }
                if manager.transcriptState.isRecording {
                    manager.stopDictationAndInsert()
                }
            },
            onCancel: { [weak self] in
                self?.manager.cancelDictation()
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
