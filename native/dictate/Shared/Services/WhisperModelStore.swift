import Foundation

struct WhisperModelStore {
    let fileManager: FileManager = .default

    func modelsDirectory() throws -> URL {
        let root = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("WhisperModels", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func localFileURL(named filename: String, isDirectory: Bool = false) throws -> URL {
        try modelsDirectory().appendingPathComponent(filename, isDirectory: isDirectory)
    }

    func resolveLocalOrBundledURL(named name: String, isDirectory: Bool = false) throws -> URL? {
        let localURL = try localFileURL(named: name, isDirectory: isDirectory)
        if fileManager.fileExists(atPath: localURL.path) {
            return localURL
        }

        return Bundle.main.url(forResource: name, withExtension: nil)
    }

    func resolveModelURL(named modelName: String) throws -> URL? {
        let normalizedCandidates = candidateNames(for: modelName)
        let directory = try modelsDirectory()

        for candidate in normalizedCandidates {
            let url = directory.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        for candidate in normalizedCandidates {
            if let bundled = Bundle.main.url(forResource: candidate, withExtension: nil) {
                return bundled
            }
        }

        return nil
    }

    private func candidateNames(for rawName: String) -> [String] {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates = [trimmed]

        if !trimmed.hasSuffix(".bin") {
            candidates.append(trimmed + ".bin")
        }

        if !trimmed.hasPrefix("ggml-") {
            candidates.append("ggml-" + trimmed)
            if !trimmed.hasSuffix(".bin") {
                candidates.append("ggml-" + trimmed + ".bin")
            }
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }
}
