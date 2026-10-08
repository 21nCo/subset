import AVFoundation
import Foundation

final class WhisperAudioProcessor {
    private let audioEngine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "dev.subset.dictate.whisper.audio")
    private let rollingWindowDuration: TimeInterval = 20.0
    private let minimumDuration: TimeInterval = 1.2
    private let emitStrideDuration: TimeInterval = 1.0

    private var sampleRate: Double = 16_000
    private var bufferedSamples: [Float] = []
    private var samplesSinceLastEmit = 0
    private var onLevel: ((Float) -> Void)?
    private var onChunk: (([Float], Int) -> Void)?

    func start(onLevel: @escaping (Float) -> Void, onChunk: @escaping ([Float], Int) -> Void) throws {
        stop()

        self.onLevel = onLevel
        self.onChunk = onChunk

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        sampleRate = format.sampleRate

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stop(flush: Bool = true) {
        if flush {
            _ = drainBufferedChunk()
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        onLevel = nil
        onChunk = nil
        samplesSinceLastEmit = 0
        bufferedSamples.removeAll(keepingCapacity: false)
    }

    func stopAndDrain() -> (samples: [Float], sampleRate: Int)? {
        let chunk = drainBufferedChunk()

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        onLevel = nil
        onChunk = nil
        samplesSinceLastEmit = 0
        bufferedSamples.removeAll(keepingCapacity: false)

        return chunk.map { ($0, Int(sampleRate)) }
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

            bufferedSamples.append(contentsOf: monoSamples)
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

    private func drainBufferedChunk() -> [Float]? {
        let minimumSamples = Int(minimumDuration * sampleRate)
        guard bufferedSamples.count >= minimumSamples else { return nil }

        let chunk = bufferedSamples
        samplesSinceLastEmit = 0
        bufferedSamples.removeAll(keepingCapacity: false)
        return chunk
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
