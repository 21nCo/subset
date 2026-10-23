import AppKit
import TimerCore

/// The built-in macOS sounds the app plays, as the daemon's `afplay` sink does (packages/timer-cli/src/alerts/macos.mjs).
/// No sound comes from a timer or a user.
enum SystemSound: String, Equatable, Sendable {
    case tink = "Tink"
    case pop = "Pop"
    case glass = "Glass"

    /// The sounds for an alert, in order: Tink for a tick, Pop for a new step, Glass three times for the finish, and
    /// none for alerts missed while away. A timer whose `sound` is off plays none.
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

/// Plays a sequence of sounds one after another; tests substitute a fake.
@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ sounds: [SystemSound])
}

/// Plays sounds with `NSSound`, each sequence in order. Sequences that overlap, such as a tick during the finish, play
/// side by side.
@MainActor
final class SystemSoundPlayer: NSObject, SoundPlaying, NSSoundDelegate {
    /// The sequences still playing, by the sound now playing in each.
    private var playing: [ObjectIdentifier: (sound: NSSound, rest: ArraySlice<SystemSound>)] = [:]

    func play(_ sounds: [SystemSound]) {
        start(sounds[...])
    }

    private func start(_ sounds: ArraySlice<SystemSound>) {
        // Each play needs its own copy: a named NSSound is shared and plays once at a time.
        guard let first = sounds.first, let sound = NSSound(named: first.rawValue)?.copy() as? NSSound else { return }
        sound.delegate = self
        playing[ObjectIdentifier(sound)] = (sound, sounds.dropFirst())
        if !sound.play() { finished(ObjectIdentifier(sound)) }
    }

    private func finished(_ id: ObjectIdentifier) {
        guard let entry = playing.removeValue(forKey: id) else { return }
        start(entry.rest)
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        let id = ObjectIdentifier(sound)
        Task { @MainActor in self.finished(id) }
    }
}
