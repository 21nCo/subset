import Foundation

struct WhisperResolvedModel: Hashable {
    let descriptor: WhisperModelDescriptor
    let modelURL: URL
    let coreMLModelURL: URL?
}

struct WhisperModelSnapshot: Hashable {
    let descriptor: WhisperModelDescriptor
    let modelURL: URL?
    let coreMLModelURL: URL?

    func statusDescription(coreMLEnabled: Bool) -> String {
        if let modelURL {
            if coreMLEnabled {
                if let coreMLModelURL {
                    return "Ready: \(modelURL.lastPathComponent) with Core ML encoder \(coreMLModelURL.lastPathComponent)."
                }
                return "Ready: \(modelURL.lastPathComponent). Core ML encoder not cached yet."
            }

            return "Ready: \(modelURL.lastPathComponent)."
        }

        return "Not downloaded yet. The model will be fetched on first dictation start."
    }
}

enum WhisperModelManagerError: LocalizedError {
    case missingModelAfterDownload(String)

    var errorDescription: String? {
        switch self {
        case .missingModelAfterDownload(let message):
            return message
        }
    }
}

struct WhisperModelManager {
    let store = WhisperModelStore()
    let downloader = WhisperModelDownloadService()

    func snapshot(for settings: DictationSettings) throws -> WhisperModelSnapshot {
        let descriptor = WhisperModelCatalog.descriptor(for: settings.whisperModelPreset)
        return try snapshot(for: descriptor)
    }

    /// Setup (Download button) and a first dictation can both prepare the same model; they
    /// share one preparation so downloads never race on the same destination files.
    func ensureLocalModel(
        for settings: DictationSettings,
        statusHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> WhisperResolvedModel {
        let key = "\(settings.whisperModelPreset.ggmlFilename)|coreml=\(settings.useCoreML)"
        return try await WhisperModelPreparationGate.shared.run(key: key) {
            try await WhisperModelManager().prepareLocalModel(for: settings, statusHandler: statusHandler)
        }
    }

    private func prepareLocalModel(
        for settings: DictationSettings,
        statusHandler: (@Sendable (String) -> Void)?
    ) async throws -> WhisperResolvedModel {
        let descriptor = WhisperModelCatalog.descriptor(for: settings.whisperModelPreset)
        var currentSnapshot = try snapshot(for: descriptor)

        if currentSnapshot.modelURL == nil {
            statusHandler?("Downloading \(descriptor.title) whisper model...")
            let destinationURL = try store.localFileURL(named: descriptor.ggmlFilename)
            _ = try await downloader.download(from: descriptor.ggmlDownloadURL, to: destinationURL)
            currentSnapshot = try snapshot(for: descriptor)
        }

        guard let modelURL = currentSnapshot.modelURL else {
            throw WhisperModelManagerError.missingModelAfterDownload(
                "The whisper model is still missing after download: \(descriptor.ggmlFilename)"
            )
        }

        var coreMLModelURL: URL?
        if settings.useCoreML {
            if currentSnapshot.coreMLModelURL == nil {
                // The encoder is optional: a failed download or extraction falls back to the
                // standard whisper.cpp encoder instead of failing dictation.
                do {
                    statusHandler?("Downloading Core ML encoder for \(descriptor.title)...")
                    let archiveURL = try store.localFileURL(named: descriptor.coreMLArchiveFilename)
                    _ = try await downloader.download(from: descriptor.coreMLArchiveDownloadURL, to: archiveURL)
                    statusHandler?("Extracting Core ML encoder...")
                    try downloader.extractArchive(at: archiveURL, into: try store.modelsDirectory())
                    try? store.fileManager.removeItem(at: archiveURL)
                    currentSnapshot = try snapshot(for: descriptor)
                } catch is CancellationError {
                    removePartialCoreMLEncoder(for: descriptor)
                    throw CancellationError()
                } catch {
                    // A failed extraction can leave a partial encoder directory, which would
                    // otherwise look cached and be handed to whisper on the next start.
                    removePartialCoreMLEncoder(for: descriptor)
                    statusHandler?("Core ML encoder download failed: \(error.localizedDescription)")
                }
            }

            if let resolvedCoreMLModelURL = currentSnapshot.coreMLModelURL {
                coreMLModelURL = resolvedCoreMLModelURL
            } else {
                statusHandler?("Core ML encoder could not be prepared. Falling back to standard whisper.cpp.")
            }
        }

        return WhisperResolvedModel(
            descriptor: descriptor,
            modelURL: modelURL,
            coreMLModelURL: coreMLModelURL
        )
    }

    private func removePartialCoreMLEncoder(for descriptor: WhisperModelDescriptor) {
        for (name, isDirectory) in [(descriptor.coreMLDirectoryName, true), (descriptor.coreMLArchiveFilename, false)] {
            if let url = try? store.localFileURL(named: name, isDirectory: isDirectory) {
                try? store.fileManager.removeItem(at: url)
            }
        }
    }

    private func snapshot(for descriptor: WhisperModelDescriptor) throws -> WhisperModelSnapshot {
        WhisperModelSnapshot(
            descriptor: descriptor,
            modelURL: try store.resolveLocalOrBundledURL(named: descriptor.ggmlFilename),
            coreMLModelURL: try store.resolveLocalOrBundledURL(named: descriptor.coreMLDirectoryName, isDirectory: true)
        )
    }
}

/// Coalesces concurrent preparations of the same model into one task.
actor WhisperModelPreparationGate {
    static let shared = WhisperModelPreparationGate()
    private var inFlight: [String: Task<WhisperResolvedModel, Error>] = [:]

    func run(key: String, operation: @escaping @Sendable () async throws -> WhisperResolvedModel) async throws -> WhisperResolvedModel {
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
