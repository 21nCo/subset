import CryptoKit
import Foundation

enum WhisperModelDownloadServiceError: LocalizedError {
    case invalidResponse(URL)
    case badStatusCode(Int, URL)
    case extractionFailed(Int32)
    case sizeMismatch(expected: Int64, actual: Int64, filename: String)
    case checksumMismatch(filename: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let url):
            return "The model download returned an invalid response: \(url.absoluteString)"
        case .badStatusCode(let code, let url):
            return "The model download failed with HTTP \(code): \(url.absoluteString)"
        case .extractionFailed(let code):
            return "Failed to extract the downloaded Core ML archive. ditto exited with code \(code)."
        case .sizeMismatch(let expected, let actual, let filename):
            return "The download of \(filename) is \(actual) bytes, expected \(expected). It was discarded."
        case .checksumMismatch(let filename):
            return "The download of \(filename) does not match its pinned SHA-256. It was discarded."
        }
    }
}

struct WhisperModelDownloadService {
    let fileManager: FileManager = .default

    /// Downloads `file` and moves it to `destinationURL` only once its size and SHA-256 match the pin.
    func download(_ file: WhisperModelFile, to destinationURL: URL) async throws -> URL {
        let remoteURL = file.downloadURL
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperModelDownloadServiceError.invalidResponse(remoteURL)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WhisperModelDownloadServiceError.badStatusCode(httpResponse.statusCode, remoteURL)
        }

        do {
            try Self.verify(fileAt: temporaryURL, matches: file)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    /// Checks the size first (cheap, catches truncation), then hashes the file in 1 MiB chunks.
    static func verify(fileAt url: URL, matches file: WhisperModelFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == file.size else {
            throw WhisperModelDownloadServiceError.sizeMismatch(expected: file.size, actual: actualSize, filename: file.filename)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else {
            throw WhisperModelDownloadServiceError.checksumMismatch(filename: file.filename)
        }
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
