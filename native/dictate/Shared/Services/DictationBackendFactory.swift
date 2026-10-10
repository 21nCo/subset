import Foundation

enum DictationBackendFactory {
    @MainActor
    static func makeBackend(for settings: DictationSettings) -> any DictationBackend {
        switch settings.backendKind {
        case .whisperCppLocal:
            return WhisperCppBackend()
        case .managedCloud:
            return CloudDictationBackend()
        case .mock:
            return MockDictationBackend()
        }
    }
}
