import AppKit
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var records: [CaptureRecord] = []

    let rootDirectory: URL
    private let mediaDirectory: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        let base = rootDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.subset.screenshot", isDirectory: true)
        self.rootDirectory = base
        mediaDirectory = base.appendingPathComponent("Media", isDirectory: true)
        indexURL = base.appendingPathComponent("history.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        load()
    }

    @discardableResult
    func saveImage(
        _ image: NSImage,
        kind: CaptureKind,
        preferredDirectory: URL? = nil,
        sourceApplication: String? = nil,
        sourceWindow: String? = nil
    ) throws -> CaptureRecord {
        let preferences = AppPreferences.shared
        let id = UUID()
        let extensionName = preferences.imageFormat.lowercased() == "jpeg" ? "jpg" : "png"
        let fileName = preferences.formattedFileName(at: Date()) + "." + extensionName
        let exportURL = uniqueURL(in: preferredDirectory ?? preferences.exportDirectory, fileName: fileName)
        let archiveURL = mediaDirectory.appendingPathComponent("\(id.uuidString).\(extensionName)")
        let data = try image.encodedData(format: extensionName, quality: preferences.jpegQuality)
        try data.write(to: exportURL, options: .atomic)
        try data.write(to: archiveURL, options: .atomic)

        let pixels = image.pixelSize
        let record = CaptureRecord(
            id: id,
            kind: kind,
            createdAt: Date(),
            fileURL: exportURL,
            projectURL: nil,
            thumbnailURL: archiveURL,
            width: Int(pixels.width),
            height: Int(pixels.height),
            sourceApplication: sourceApplication,
            sourceWindow: sourceWindow,
            cloudShareURL: nil,
            cloudID: nil,
            tags: [],
            isFavorite: false
        )
        records.insert(record, at: 0)
        persist()
        pruneExpired()
        return record
    }

    func saveRecording(at url: URL, kind: CaptureKind, pixelSize: CGSize) throws -> CaptureRecord {
        let id = UUID()
        let destination = mediaDirectory.appendingPathComponent("\(id.uuidString).\(url.pathExtension)")
        if url.standardizedFileURL != destination.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: url, to: destination)
        }
        let record = CaptureRecord(
            id: id,
            kind: kind,
            createdAt: Date(),
            fileURL: url,
            projectURL: nil,
            thumbnailURL: destination,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            sourceApplication: nil,
            sourceWindow: nil,
            cloudShareURL: nil,
            cloudID: nil,
            tags: [],
            isFavorite: false
        )
        records.insert(record, at: 0)
        persist()
        return record
    }

    func updateCloud(id: UUID, shareURL: URL, cloudID: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].cloudShareURL = shareURL
        records[index].cloudID = cloudID
        persist()
    }

    func updateTags(id: UUID, tags: [String]) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].tags = tags
        persist()
    }

    func clearCloud(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].cloudShareURL = nil
        records[index].cloudID = nil
        persist()
    }

    func toggleFavorite(id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isFavorite.toggle()
        persist()
    }

    func delete(_ record: CaptureRecord) {
        records.removeAll { $0.id == record.id }
        if let thumbnailURL = record.thumbnailURL { try? fileManager.removeItem(at: thumbnailURL) }
        if let projectURL = record.projectURL { try? fileManager.removeItem(at: projectURL) }
        persist()
    }

    func clear() {
        for record in records {
            if let thumbnailURL = record.thumbnailURL { try? fileManager.removeItem(at: thumbnailURL) }
            if let projectURL = record.projectURL { try? fileManager.removeItem(at: projectURL) }
        }
        records = []
        persist()
    }

    func restoreMostRecent() -> CaptureRecord? {
        records.first(where: { fileManager.fileExists(atPath: $0.fileURL.path) || ($0.thumbnailURL.map { fileManager.fileExists(atPath: $0.path) } ?? false) })
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? decoder.decode([CaptureRecord].self, from: data) else { return }
        records = decoded.sorted { $0.createdAt > $1.createdAt }
        pruneExpired()
    }

    private func persist() {
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func pruneExpired() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -AppPreferences.shared.historyDays, to: Date()) ?? .distantPast
        let expired = records.filter { !$0.isFavorite && $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        for record in expired {
            if let thumbnailURL = record.thumbnailURL { try? fileManager.removeItem(at: thumbnailURL) }
            if let projectURL = record.projectURL { try? fileManager.removeItem(at: projectURL) }
        }
        records.removeAll { record in expired.contains(where: { $0.id == record.id }) }
        persist()
    }

    private func uniqueURL(in directory: URL, fileName: String) -> URL {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let proposed = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }
        let base = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        for index in 2...10_000 {
            let candidate = directory.appendingPathComponent("\(base) \(index).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }
}

extension NSImage {
    var pixelSize: CGSize {
        if let representation = representations.first {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return size
    }

    func encodedData(format: String, quality: Double = 0.92) throws -> Data {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let type: NSBitmapImageRep.FileType = format.lowercased() == "jpg" || format.lowercased() == "jpeg" ? .jpeg : .png
        let properties: [NSBitmapImageRep.PropertyKey: Any] = type == .jpeg ? [.compressionFactor: quality] : [:]
        guard let data = bitmap.representation(using: type, properties: properties) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
