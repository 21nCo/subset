import Foundation

enum WhisperModelDownloadServiceError: LocalizedError {
    case invalidResponse(URL)
    case badStatusCode(Int, URL)
    case extractionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let url):
            return "The model download returned an invalid response: \(url.absoluteString)"
        case .badStatusCode(let code, let url):
            return "The model download failed with HTTP \(code): \(url.absoluteString)"
        case .extractionFailed(let code):
            return "Failed to extract the downloaded Core ML archive. ditto exited with code \(code)."
        }
    }
}

struct WhisperModelDownloadService {
    let fileManager: FileManager = .default

    func download(from remoteURL: URL, to destinationURL: URL) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperModelDownloadServiceError.invalidResponse(remoteURL)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WhisperModelDownloadServiceError.badStatusCode(httpResponse.statusCode, remoteURL)
        }

        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    func extractArchive(at archiveURL: URL, into destinationDirectoryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationDirectoryURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WhisperModelDownloadServiceError.extractionFailed(process.terminationStatus)
        }
    }
}
