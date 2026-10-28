import AppKit
import TimerCore

/// The built-in macOS sounds the app plays, as the daemon's `afplay` sink does (packages/timer-cli/src/alerts/macos.mjs).
/// No sound comes from a timer or a user.
enum SystemSound: String, Equatable, Sendable {
    case tink = "Tink"
    case pop = "Pop"
    case glass = "Glass"

    /// The sounds for an alert, in order: Tink for a tick, Pop for a new step, Glass three times for the finish, and
    /// none for alerts missed while away. A timer whose `sound` is off plays none. `AlertPart.sound(i)` is the i-th.
    static func sequence(for kind: TimerAlert.Kind, soundOn: Bool) -> [SystemSound] {
        guard soundOn else { return [] }
        switch kind {
        case .tick: return [.tink]
        case .segment: return [.pop]
        case .finish: return [.glass, .glass, .glass]
        case .missedWhileAway: return []
        }
    }
}

/// Plays one sound and returns once it has finished; tests substitute a fake.
@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ sound: SystemSound) async
}

/// Plays sounds with `NSSound`. Sounds of alerts that overlap, such as a tick during the finish, play side by side.
@MainActor
final class SystemSoundPlayer: NSObject, SoundPlaying, NSSoundDelegate {
    /// The sounds still playing, each with what waits for it to finish.
    private var playing: [ObjectIdentifier: (sound: NSSound, finished: CheckedContinuation<Void, Never>)] = [:]

    func play(_ sound: SystemSound) async {
        // Each play needs its own copy: a named NSSound is shared and plays once at a time.
        guard let copy = NSSound(named: sound.rawValue)?.copy() as? NSSound else { return }
        copy.delegate = self
        await withCheckedContinuation { continuation in
            playing[ObjectIdentifier(copy)] = (copy, continuation)
            if !copy.play() { finished(ObjectIdentifier(copy)) }
        }
    }

    private func finished(_ id: ObjectIdentifier) {
        playing.removeValue(forKey: id)?.finished.resume()
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        let id = ObjectIdentifier(sound)
        Task { @MainActor in self.finished(id) }
    }
}
