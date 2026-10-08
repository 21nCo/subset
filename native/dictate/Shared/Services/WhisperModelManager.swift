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

    func ensureLocalModel(
        for settings: DictationSettings,
        statusHandler: (@Sendable (String) -> Void)? = nil
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
                statusHandler?("Downloading Core ML encoder for \(descriptor.title)...")
                let archiveURL = try store.localFileURL(named: descriptor.coreMLArchiveFilename)
                _ = try await downloader.download(from: descriptor.coreMLArchiveDownloadURL, to: archiveURL)
                statusHandler?("Extracting Core ML encoder...")
                try downloader.extractArchive(at: archiveURL, into: try store.modelsDirectory())
                try? store.fileManager.removeItem(at: archiveURL)
                currentSnapshot = try snapshot(for: descriptor)
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

    private func snapshot(for descriptor: WhisperModelDescriptor) throws -> WhisperModelSnapshot {
        WhisperModelSnapshot(
            descriptor: descriptor,
            modelURL: try store.resolveLocalOrBundledURL(named: descriptor.ggmlFilename),
            coreMLModelURL: try store.resolveLocalOrBundledURL(named: descriptor.coreMLDirectoryName, isDirectory: true)
        )
    }
}
