import Foundation

/// One downloadable file, pinned to its size and SHA-256 so a replaced or truncated upstream
/// file is rejected before it reaches the whisper.cpp loader or `ditto`.
struct WhisperModelFile: Hashable {
    let filename: String
    let downloadURL: URL
    let sha256: String
    let size: Int64
}

struct WhisperModelDescriptor: Hashable {
    let preset: WhisperModelPreset
    let ggml: WhisperModelFile
    let coreMLArchive: WhisperModelFile
    let coreMLDirectoryName: String

    var ggmlFilename: String { ggml.filename }
    var coreMLArchiveFilename: String { coreMLArchive.filename }

    var title: String {
        preset.title
    }
}

enum WhisperModelCatalog {
    /// The `ggerganov/whisper.cpp` Hugging Face commit the hashes below were taken from. Downloading
    /// from a commit rather than `main` keeps the files fixed; change the revision and every hash together.
    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let baseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(revision)")!

    private struct Pin {
        let ggmlSHA256: String
        let ggmlSize: Int64
        let coreMLSHA256: String
        let coreMLSize: Int64
    }

    private static func pin(for preset: WhisperModelPreset) -> Pin {
        switch preset {
        case .tinyEn:
            return Pin(
                ggmlSHA256: "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
                ggmlSize: 77_704_715,
                coreMLSHA256: "82b32eef73c94bb0c432a776a047b757d9525c26d84038a15d8798d7c8d1ee58",
                coreMLSize: 15_034_655
            )
        case .baseEn:
            return Pin(
                ggmlSHA256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
                ggmlSize: 147_964_211,
                coreMLSHA256: "8cf860309e2449e2bdc8be834cf838ab2565747ecc8c0ef914ef5975115e192b",
                coreMLSize: 37_950_917
            )
        case .smallEn:
            return Pin(
                ggmlSHA256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
                ggmlSize: 487_614_201,
                coreMLSHA256: "b2ef1c506378b825b4b4341979a93e1656b5d6c129f17114cfb8fb78aabc2f89",
                coreMLSize: 162_952_446
            )
        }
    }

    static func descriptor(for preset: WhisperModelPreset) -> WhisperModelDescriptor {
        let pin = pin(for: preset)
        return WhisperModelDescriptor(
            preset: preset,
            ggml: WhisperModelFile(
                filename: preset.ggmlFilename,
                downloadURL: baseURL.appendingPathComponent(preset.ggmlFilename),
                sha256: pin.ggmlSHA256,
                size: pin.ggmlSize
            ),
            coreMLArchive: WhisperModelFile(
                filename: preset.coreMLArchiveFilename,
                downloadURL: baseURL.appendingPathComponent(preset.coreMLArchiveFilename),
                sha256: pin.coreMLSHA256,
                size: pin.coreMLSize
            ),
            coreMLDirectoryName: preset.coreMLDirectoryName
        )
    }
}
