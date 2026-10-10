import AVFoundation
import Foundation

enum WhisperAudioProcessorError: LocalizedError {
    case noUsableInput

    var errorDescription: String? {
        "No usable microphone input is available. Check the input device in System Settings > Sound."
    }
}

final class WhisperAudioProcessor {
    private let audioEngine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "dev.subset.dictate.whisper.audio")
    private let rollingWindowDuration: TimeInterval = 20.0
    private let minimumDuration: TimeInterval = 1.2
    private let emitStrideDuration: TimeInterval = 1.0

    /// Upper bound on audio kept for the final pass (memory guard for very long holds).
    private let maximumSessionDuration: TimeInterval = 15 * 60

    // Everything below is only touched on `processingQueue` once capture starts.
    private var sampleRate: Double = 16_000
    /// The last `rollingWindowDuration` of audio, used for live partial transcripts.
    private var bufferedSamples: [Float] = []
    /// All audio of the session, used for the final transcript so long dictations keep
    /// their opening words.
    private var sessionSamples: [Float] = []
    private var samplesSinceLastEmit = 0
    private var onLevel: ((Float) -> Void)?
    private var onChunk: (([Float], Int) -> Void)?
    private var onSessionLimitReached: (() -> Void)?

    func start(
        onLevel: @escaping (Float) -> Void,
        onChunk: @escaping ([Float], Int) -> Void,
        onSessionLimitReached: @escaping () -> Void = {}
    ) throws {
        stop()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A missing or disconnected input reports an empty format; installing a tap with it
        // raises an AVAudioEngine exception instead of a catchable error.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WhisperAudioProcessorError.noUsableInput
        }
        processingQueue.sync {
            self.sampleRate = format.sampleRate
            self.onLevel = onLevel
            self.onChunk = onChunk
            self.onSessionLimitReached = onSessionLimitReached
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Stops capture and discards buffered audio.
    func stop() {
        _ = stopAndDrain()
    }

    /// Stops capture and returns all audio captured in the session (if any), including tap
    /// buffers still queued for processing.
    func stopAndDrain() -> (samples: [Float], sampleRate: Int)? {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()

        // The queue is serial, so this runs after every buffer the tap already handed over.
        return processingQueue.sync {
            let chunk = sessionSamples
            let rate = Int(sampleRate)
            onLevel = nil
            onChunk = nil
            onSessionLimitReached = nil
            samplesSinceLastEmit = 0
            bufferedSamples.removeAll(keepingCapacity: false)
            sessionSamples.removeAll(keepingCapacity: false)
            // Any audio is handed to the backend; it rejects silence or too-short speech itself.
            return chunk.isEmpty ? nil : (chunk, rate)
        }
    }

    private func consume(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        let channels = (0..<channelCount).map { channelIndex in
            Array(UnsafeBufferPointer(start: channelData[channelIndex], count: frameLength))
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            let monoSamples: [Float]

            if channelCount == 1 {
                monoSamples = channels[0]
            } else {
                var downmixed: [Float] = []
                downmixed.reserveCapacity(frameLength)
                for frame in 0..<frameLength {
                    let sum = channels.reduce(Float.zero) { partial, channel in
                        partial + channel[frame]
                    }
                    downmixed.append(sum / Float(channelCount))
                }
                monoSamples = downmixed
            }

            guard onChunk != nil else { return }
            bufferedSamples.append(contentsOf: monoSamples)
            let maximumSessionSamples = Int(maximumSessionDuration * sampleRate)
            if sessionSamples.count < maximumSessionSamples {
                sessionSamples.append(contentsOf: monoSamples)
                if sessionSamples.count >= maximumSessionSamples {
                    // Reported once, so the user knows later speech is not in the final text.
                    onSessionLimitReached?()
                }
            }
            samplesSinceLastEmit += monoSamples.count
            onLevel?(rmsLevel(for: monoSamples))
            emitChunk(force: false)
        }
    }

    private func emitChunk(force: Bool) {
        let minimumSamples = Int(minimumDuration * sampleRate)
        let emitStrideSamples = Int(emitStrideDuration * sampleRate)
        let maxWindowSamples = Int(rollingWindowDuration * sampleRate)

        guard bufferedSamples.count >= minimumSamples else { return }
        guard force || samplesSinceLastEmit >= emitStrideSamples else { return }

        if bufferedSamples.count > maxWindowSamples {
            bufferedSamples.removeFirst(bufferedSamples.count - maxWindowSamples)
        }

        samplesSinceLastEmit = 0
        onChunk?(bufferedSamples, Int(sampleRate))
    }

    private func rmsLevel(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float.zero) { partial, sample in
            partial + (sample * sample)
        } / Float(samples.count)

        let rms = sqrt(meanSquare)
        return min(max(rms * 8, 0), 1)
    }
}

extension WhisperAudioProcessor: @unchecked Sendable {}
