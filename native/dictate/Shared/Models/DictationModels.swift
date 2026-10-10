import Foundation

enum DictationBackendKind: String, Codable, CaseIterable, Identifiable {
    case whisperCppLocal
    case managedCloud
    case mock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisperCppLocal:
            return "Local whisper.cpp"
        case .managedCloud:
            return "Managed cloud"
        case .mock:
            return "Mock stream"
        }
    }
}

enum WhisperModelPreset: String, Codable, CaseIterable, Identifiable {
    case tinyEn = "tiny.en"
    case baseEn = "base.en"
    case smallEn = "small.en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tinyEn:
            return "Tiny"
        case .baseEn:
            return "Base"
        case .smallEn:
            return "Small"
        }
    }

    var subtitle: String {
        switch self {
        case .tinyEn:
            return "Fastest startup"
        case .baseEn:
            return "Best balance"
        case .smallEn:
            return "Best accuracy"
        }
    }

    var ggmlFilename: String {
        "ggml-\(rawValue).bin"
    }

    var coreMLArchiveFilename: String {
        "ggml-\(rawValue)-encoder.mlmodelc.zip"
    }

    var coreMLDirectoryName: String {
        "ggml-\(rawValue)-encoder.mlmodelc"
    }

    static func infer(from modelName: String?) -> WhisperModelPreset? {
        let normalized = (modelName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return nil }
        if normalized.contains("small") {
            return .smallEn
        }
        if normalized.contains("tiny") {
            return .tinyEn
        }
        if normalized.contains("base") {
            return .baseEn
        }
        return nil
    }
}

struct DictationSettings: Codable, Hashable {
    static let defaultAppGroupID = "group.dev.subset.dictate"

    var backendKind: DictationBackendKind
    var whisperModelPreset: WhisperModelPreset
    var localModelName: String
    var useCoreML: Bool
    var deployedModelName: String
    var deployedEndpointURL: String
    var appGroupID: String

    static let `default` = DictationSettings(
        backendKind: .whisperCppLocal,
        whisperModelPreset: .baseEn,
        localModelName: WhisperModelPreset.baseEn.ggmlFilename,
        useCoreML: true,
        deployedModelName: "managed-dictation-v1",
        deployedEndpointURL: "https://example.com/transcribe",
        appGroupID: DictationSettings.defaultAppGroupID
    )

    init(
        backendKind: DictationBackendKind,
        whisperModelPreset: WhisperModelPreset,
        localModelName: String,
        useCoreML: Bool,
        deployedModelName: String,
        deployedEndpointURL: String,
        appGroupID: String
    ) {
        self.backendKind = backendKind
        self.whisperModelPreset = whisperModelPreset
        self.localModelName = localModelName
        self.useCoreML = useCoreML
        self.deployedModelName = deployedModelName
        self.deployedEndpointURL = deployedEndpointURL
        self.appGroupID = appGroupID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let defaults = DictationSettings.default
        backendKind = try container.decodeIfPresent(DictationBackendKind.self, forKey: .backendKind) ?? defaults.backendKind
        let decodedPreset = try container.decodeIfPresent(WhisperModelPreset.self, forKey: .whisperModelPreset)
        let decodedLocalModelName = try container.decodeIfPresent(String.self, forKey: .localModelName)
        whisperModelPreset = decodedPreset ?? WhisperModelPreset.infer(from: decodedLocalModelName) ?? .baseEn
        localModelName = decodedLocalModelName ?? whisperModelPreset.ggmlFilename
        useCoreML = try container.decodeIfPresent(Bool.self, forKey: .useCoreML) ?? defaults.useCoreML
        deployedModelName = try container.decodeIfPresent(String.self, forKey: .deployedModelName) ?? defaults.deployedModelName
        deployedEndpointURL = try container.decodeIfPresent(String.self, forKey: .deployedEndpointURL) ?? defaults.deployedEndpointURL
        appGroupID = try container.decodeIfPresent(String.self, forKey: .appGroupID) ?? defaults.appGroupID
    }
}

struct TranscriptionSegment: Codable, Hashable, Identifiable {
    let id: UUID
    let text: String
    let isFinal: Bool
    let createdAt: Date

    init(id: UUID = UUID(), text: String, isFinal: Bool, createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.createdAt = createdAt
    }
}

struct SharedTranscriptState: Codable, Hashable {
    var isRecording: Bool
    var startedAt: Date?
    var backendKind: DictationBackendKind
    var statusMessage: String
    var partialText: String
    var committedText: String
    var segments: [TranscriptionSegment]
    var updatedAt: Date

    static let empty = SharedTranscriptState(
        isRecording: false,
        startedAt: nil,
        backendKind: .whisperCppLocal,
        statusMessage: "Ready.",
        partialText: "",
        committedText: "",
        segments: [],
        updatedAt: .now
    )
}

struct DictationContext: Hashable {
    let settings: DictationSettings
}

enum TranscriptionEvent: Hashable {
    case status(String)
    case partial(String)
    case final(String)
    case level(Float)
}

@MainActor
protocol DictationBackend: AnyObject {
    var kind: DictationBackendKind { get }
    var displayName: String { get }

    func startStreaming(context: DictationContext) -> AsyncThrowingStream<TranscriptionEvent, Error>
    func stopStreaming() async
}
