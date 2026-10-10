import Foundation
import AVFoundation

enum WhisperCppBackendError: LocalizedError {
    case microphonePermissionDenied
    case missingModel(String)
    case wrapperUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for local whisper.cpp dictation."
        case .missingModel(let message):
            return message
        case .wrapperUnavailable(let message):
            return message
        }
    }
}

final class WhisperCppBackend: DictationBackend {
    let kind: DictationBackendKind = .whisperCppLocal
    let displayName = "Local whisper.cpp"

    private var streamTask: Task<Void, Never>?
    private let audioProcessor = WhisperAudioProcessor()
    private let transcriptionQueue = DispatchQueue(label: "dev.subset.dictate.whisper.transcription")
    private var continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?
    private var streamingSession: WhisperStreamingSession?
    private var isRecording = false
    /// True while a live-partial pass is running; newer chunks are skipped instead of queued
    /// behind it, so the final pass after release never waits on stale partials.
    private var isTranscribingPartial = false

    func startStreaming(context: DictationContext) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            streamTask?.cancel()
            self.continuation = continuation
            self.streamingSession = nil

            streamTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await prepareAndStart(context: context)
                } catch is CancellationError {
                    // stopStreaming() already finished the stream.
                } catch {
                    failStream(error)
                }
            }
        }
    }

    func stopStreaming() async {
        streamTask?.cancel()
        streamTask = nil

        let finalChunk = audioProcessor.stopAndDrain()
        if let finalChunk {
            await transcribeChunkBeforeFinish(samples: finalChunk.samples, sampleRate: finalChunk.sampleRate)
        } else if let finalText = streamingSession?.latestTranscript, !finalText.isEmpty {
            continuation?.yield(.final(finalText))
        }

        isRecording = false
        continuation?.yield(.status("Local dictation stopped."))
        continuation?.finish()
        continuation = nil
        streamingSession = nil
    }

    private func prepareAndStart(context: DictationContext) async throws {
        let permissionGranted = await requestMicrophonePermissionIfNeeded()
        guard permissionGranted else {
            throw WhisperCppBackendError.microphonePermissionDenied
        }

        try Task.checkCancellation()

        let modelManager = WhisperModelManager()
        let resolvedModel = try await modelManager.ensureLocalModel(for: context.settings) { [weak self] status in
            Task { @MainActor [weak self] in
                self?.continuation?.yield(.status(status))
            }
        }
        try Task.checkCancellation()

        // Loading the model can take seconds; keep it off the main actor.
        let modelPath = resolvedModel.modelURL.path
        let coreMLModelPath = resolvedModel.coreMLModelURL?.path
        let loadedSession = await Task.detached(priority: .userInitiated) {
            WhisperStreamingSession(modelPath: modelPath, coreMLModelPath: coreMLModelPath)
        }.value
        // If the key was released while preparing, never turn the microphone on.
        try Task.checkCancellation()
        guard let session = loadedSession else {
            throw WhisperCppBackendError.wrapperUnavailable(
                "Whisper wrapper could not initialize. Add whisper.xcframework and the whisper headers to the Xcode target."
            )
        }
        self.streamingSession = session
        isRecording = true
        let encoderSuffix = resolvedModel.coreMLModelURL == nil ? "" : " with Core ML encoder"
        continuation?.yield(.status("Local whisper.cpp ready. Listening with model \(resolvedModel.modelURL.lastPathComponent)\(encoderSuffix)."))

        try audioProcessor.start(onLevel: { [weak self] level in
            Task { @MainActor [weak self] in
                self?.continuation?.yield(.level(level))
            }
        }, onChunk: { [weak self] samples, sampleRate in
            Task { @MainActor [weak self] in
                self?.transcribeChunk(samples: samples, sampleRate: sampleRate)
            }
        })
    }

    @MainActor
    private func transcribeChunk(samples: [Float], sampleRate: Int) {
        guard isRecording, !isTranscribingPartial else { return }
        guard let continuation, let streamingSession else { return }
        isTranscribingPartial = true

        transcriptionQueue.async { [weak self, streamingSession] in
            do {
                let output = try streamingSession.process(samples: samples, sampleRate: sampleRate, finalize: false)
                Task { @MainActor [weak self] in
                    self?.isTranscribingPartial = false
                    if let partial = output?.partial { continuation.yield(.partial(partial)) }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isTranscribingPartial = false
                    self?.failStream(error)
                }
            }
        }
    }

    /// Ends the session after an error: stops the microphone before reporting the failure.
    @MainActor
    private func failStream(_ error: Error) {
        streamTask?.cancel()
        streamTask = nil
        audioProcessor.stop()
        isRecording = false
        continuation?.finish(throwing: error)
        continuation = nil
        streamingSession = nil
    }

    @MainActor
    private func transcribeChunkBeforeFinish(samples: [Float], sampleRate: Int) async {
        guard let continuation, let streamingSession else { return }

        await withCheckedContinuation { completion in
            transcriptionQueue.async { [streamingSession] in
                do {
                    let output = try streamingSession.process(samples: samples, sampleRate: sampleRate, finalize: true)
                    Task { @MainActor in
                        if let partial = output?.partial {
                            continuation.yield(.partial(partial))
                        }

                        if let final = output?.final {
                            continuation.yield(.final(final))
                        }
                        completion.resume()
                    }
                } catch {
                    Task { @MainActor in
                        continuation.finish(throwing: error)
                        completion.resume()
                    }
                }
            }
        }
    }

    fileprivate nonisolated static func prepareSamplesForDictation(_ samples: [Float], sampleRate: Int) -> [Float]? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        let rms = sqrt(samples.reduce(Float.zero) { partial, sample in
            partial + (sample * sample)
        } / Float(samples.count))

        // Drop almost-silent chunks before whisper hallucinates text.
        guard rms > 0.0035 else { return nil }

        let edgeThreshold: Float = max(0.008, rms * 0.45)
        let paddingSamples = max(Int(Double(sampleRate) * 0.15), 1)

        guard let firstVoice = samples.firstIndex(where: { abs($0) >= edgeThreshold }),
              let lastVoice = samples.lastIndex(where: { abs($0) >= edgeThreshold }) else {
            return nil
        }

        let start = max(0, firstVoice - paddingSamples)
        let end = min(samples.count - 1, lastVoice + paddingSamples)
        guard end >= start else { return nil }

        let trimmed = Array(samples[start...end])
        let minimumSpeechSamples = max(Int(Double(sampleRate) * 0.35), 1)
        return trimmed.count >= minimumSpeechSamples ? trimmed : nil
    }

    fileprivate nonisolated static func sanitizeTranscript(_ text: String) -> String {
        let blankAudioPattern = #"\[(?:BLANK_AUDIO|MUSIC|NOISE|LAUGHTER|APPLAUSE)[^\]]*\]"#
        let stripped = text.replacingOccurrences(
            of: blankAudioPattern,
            with: " ",
            options: .regularExpression
        )

        let collapsedWhitespace = stripped.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await Self.requestMicrophoneAccess()
        @unknown default:
            return false
        }
    }

    nonisolated private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private struct WhisperStreamingOutput {
    let partial: String?
    let final: String?
}

private final class WhisperStreamingSession: @unchecked Sendable {
    private let wrapper: WhisperCppWrapper
    private(set) var latestTranscript = ""
    private var lastYieldedTranscript = ""

    init?(modelPath: String, coreMLModelPath: String?) {
        guard let wrapper = WhisperCppWrapper(modelPath: modelPath, coreMLModelPath: coreMLModelPath) else {
            return nil
        }
        self.wrapper = wrapper
    }

    func process(samples: [Float], sampleRate: Int, finalize: Bool) throws -> WhisperStreamingOutput? {
        if let preparedSamples = WhisperCppBackend.prepareSamplesForDictation(samples, sampleRate: sampleRate) {
            let rawText = try preparedSamples.withUnsafeBufferPointer { buffer -> String? in
                guard let baseAddress = buffer.baseAddress else {
                    return nil
                }

                return try wrapper.transcribeAudio(
                    fromPCMData: baseAddress,
                    sampleCount: Int32(buffer.count),
                    sampleRate: Int32(sampleRate),
                    language: "en",
                    enableDiarization: false,
                    enableTimestamps: false,
                    enableImprovedFormat: true
                )
            }

            let normalized = collapseImmediateRepetitions(
                in: WhisperCppBackend.sanitizeTranscript(rawText ?? ""),
                previous: latestTranscript
            )
            if !normalized.isEmpty {
                latestTranscript = normalized
            }
        }

        guard !latestTranscript.isEmpty else { return nil }

        let partial: String?
        if latestTranscript != lastYieldedTranscript {
            partial = latestTranscript
            lastYieldedTranscript = latestTranscript
        } else {
            partial = nil
        }

        let final = finalize ? latestTranscript : nil
        return WhisperStreamingOutput(partial: partial, final: final)
    }

    private func collapseImmediateRepetitions(in text: String, previous: String) -> String {
        guard !text.isEmpty else { return text }

        if !previous.isEmpty {
            let collapsedAgainstPrevious = collapseRepeatingBase(text, base: previous)
            if !collapsedAgainstPrevious.isEmpty {
                return collapsedAgainstPrevious
            }
        }

        return collapsePeriodicText(text)
    }

    private func collapseRepeatingBase(_ text: String, base: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty, !trimmedBase.isEmpty else { return trimmedText }
        guard trimmedText.count > trimmedBase.count, trimmedText.hasPrefix(trimmedBase) else { return trimmedText }

        var remainder = String(trimmedText.dropFirst(trimmedBase.count))
        let spacerCharacterSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

        while let firstScalar = remainder.unicodeScalars.first, spacerCharacterSet.contains(firstScalar) {
            remainder.removeFirst()
        }

        guard !remainder.isEmpty else { return trimmedBase }

        while remainder.hasPrefix(trimmedBase) {
            remainder.removeFirst(trimmedBase.count)
            while let firstScalar = remainder.unicodeScalars.first, spacerCharacterSet.contains(firstScalar) {
                remainder.removeFirst()
            }
        }

        return remainder.isEmpty ? trimmedBase : trimmedText
    }

    private func collapsePeriodicText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = trimmed.count
        guard length >= 8 else { return trimmed }

        for unitLength in 4...(length / 2) {
            guard length >= unitLength * 2 else { continue }
            let unitEnd = trimmed.index(trimmed.startIndex, offsetBy: unitLength)
            let unit = String(trimmed[..<unitEnd])
            guard unit.contains(" ") else { continue }

            let collapsed = collapseRepeatingBase(trimmed, base: unit)
            if collapsed.count < trimmed.count {
                return collapsed
            }
        }

        return trimmed
    }
}
