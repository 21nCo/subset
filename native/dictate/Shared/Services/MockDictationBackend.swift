import Foundation

final class MockDictationBackend: DictationBackend {
    let kind: DictationBackendKind = .mock
    let displayName = "Mock stream"

    private var streamTask: Task<Void, Never>?

    func startStreaming(context: DictationContext) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                continuation.yield(.status("Mock backend started. This validates the end-to-end insertion flow."))

                let batches: [[String]] = [
                    ["shipping", "the", "macOS", "dictation", "app"],
                    ["requires", "a", "floating", "activation", "panel"],
                    ["with", "real", "time", "transcription", "and", "text", "insertion"]
                ]

                for batch in batches {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    var partial = ""
                    for word in batch {
                        try? await Task.sleep(for: .milliseconds(250))
                        partial = partial.isEmpty ? word : "\(partial) \(word)"
                        continuation.yield(.partial(partial))
                    }

                    try? await Task.sleep(for: .milliseconds(180))
                    continuation.yield(.final(batch.joined(separator: " ")))
                }

                continuation.yield(.status("Mock backend finished."))
                continuation.finish()
            }
        }
    }

    func stopStreaming() async {
        streamTask?.cancel()
        streamTask = nil
    }
}
