import Foundation

struct SharedTranscriptStore {
    nonisolated(unsafe) static let shared = SharedTranscriptStore()

    private let settingsKey = "dictation.settings"
    private let stateKey = "dictation.state"
    private let defaults: UserDefaults

    init(suiteName: String = DictationSettings.defaultAppGroupID) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func loadSettings() -> DictationSettings {
        guard
            let data = defaults.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode(DictationSettings.self, from: data)
        else {
            return .default
        }

        return settings
    }

    func save(settings: DictationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    func loadState() -> SharedTranscriptState {
        guard
            let data = defaults.data(forKey: stateKey),
            let state = try? JSONDecoder().decode(SharedTranscriptState.self, from: data)
        else {
            return .empty
        }

        return state
    }

    func save(state: SharedTranscriptState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }
}
