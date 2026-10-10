import Foundation

struct WhisperModelDescriptor: Hashable {
    let preset: WhisperModelPreset
    let ggmlFilename: String
    let ggmlDownloadURL: URL
    let coreMLArchiveFilename: String
    let coreMLArchiveDownloadURL: URL
    let coreMLDirectoryName: String

    var title: String {
        preset.title
    }
}

enum WhisperModelCatalog {
    private static let baseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main")!

    static func descriptor(for preset: WhisperModelPreset) -> WhisperModelDescriptor {
        WhisperModelDescriptor(
            preset: preset,
            ggmlFilename: preset.ggmlFilename,
            ggmlDownloadURL: baseURL.appendingPathComponent(preset.ggmlFilename),
            coreMLArchiveFilename: preset.coreMLArchiveFilename,
            coreMLArchiveDownloadURL: baseURL.appendingPathComponent(preset.coreMLArchiveFilename),
            coreMLDirectoryName: preset.coreMLDirectoryName
        )
    }
}
