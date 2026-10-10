import AVFoundation
import Foundation

@MainActor
final class BreakSoundCoordinator {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConnected = false
    private var filePlayer: AVAudioPlayer?
    /// Identifies the latest tone, so an older tone's completion does not stop a newer one.
    private var generation = 0

    func play(name: String, volume: Double, customFilename: String?, isCompletion: Bool) {
        guard name != "None", volume > 0 else { return }
        if name == "Custom audio",
           let customFilename,
           let url = AppGroupAssets.url(for: customFilename),
           let player = try? AVAudioPlayer(contentsOf: url) {
            // Same session as the generated tones: mix with, rather than interrupt, other audio.
            guard activateSession() else { return }
            filePlayer = player
            player.volume = Float(min(1, max(0, volume)))
            player.prepareToPlay()
            player.play()
            return
        }
        let sampleRate = 44_100.0
        let duration = isCompletion ? 1.45 : 2.1
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleRate * duration)
            )
        else { return }

        buffer.frameLength = buffer.frameCapacity
        let frequencies = tones(for: name, completion: isCompletion)
        let gain = Float(min(1, max(0, volume))) * 0.22
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(buffer.frameLength) {
                let t = Double(frame) / sampleRate
                let attack = min(1, t / 0.045)
                let decay = exp(-3.8 * t / duration)
                let shimmer = 0.30 * sin(2 * .pi * frequencies.1 * t)
                let fundamental = sin(2 * .pi * frequencies.0 * t)
                samples[frame] = gain * Float(attack * decay * (fundamental + shimmer))
            }
        }

        guard activateSession() else { return }
        do {
            if !isConnected {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                isConnected = true
            }
            if !engine.isRunning { try engine.start() }
            player.stop()
            generation += 1
            let current = generation
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finishTone(generation: current) }
            }
            player.play()
        } catch {
            player.stop()
        }
    }

    /// Stops the engine and releases the audio session once the latest tone has played, so an idle
    /// coordinator does not keep the audio route active.
    private func finishTone(generation finished: Int) {
        guard finished == generation else { return }
        player.stop()
        engine.stop()
        #if os(iOS)
        if filePlayer?.isPlaying != true {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private func activateSession() -> Bool {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return false
        }
        #endif
        return true
    }

    private func tones(for name: String, completion: Bool) -> (Double, Double) {
        let base: (Double, Double)
        switch name {
        case "Tibetan bell": base = (220, 659.25)
        case "Forest tone": base = (293.66, 440)
        case "Quiet pulse": base = (196, 392)
        default: base = (329.63, 659.25)
        }
        return completion ? (base.0 * 1.25, base.1 * 1.25) : base
    }
}
