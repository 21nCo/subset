import Foundation

final class CloudDictationBackend: DictationBackend {
    let kind: DictationBackendKind = .managedCloud
    let displayName = "Managed cloud"

    private var streamTask: Task<Void, Never>?

    func startStreaming(context: DictationContext) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                continuation.yield(.status("Cloud adapter scaffold active. Replace this with your deployed-model streaming client."))
                continuation.yield(.partial("connecting to \(context.settings.deployedModelName)"))
                try? await Task.sleep(for: .milliseconds(450))
                continuation.yield(.final("cloud backend ready for endpoint integration"))
                continuation.finish()
            }
        }
    }

    func stopStreaming() async {
        streamTask?.cancel()
        streamTask = nil
    }
}
