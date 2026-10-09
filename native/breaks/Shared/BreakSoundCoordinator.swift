import AVFoundation
import Foundation

@MainActor
final class BreakSoundCoordinator {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConnected = false
    private var filePlayer: AVAudioPlayer?

    func play(name: String, volume: Double, customFilename: String?, isCompletion: Bool) {
        guard name != "None", volume > 0 else { return }
        if name == "Custom audio",
           let customFilename,
           let url = AppGroupAssets.url(for: customFilename),
           let player = try? AVAudioPlayer(contentsOf: url) {
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

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            #endif
            if !isConnected {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                isConnected = true
            }
            if !engine.isRunning { try engine.start() }
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
        } catch {
            player.stop()
        }
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
