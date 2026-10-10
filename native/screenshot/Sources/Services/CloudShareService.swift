import Foundation

struct CloudUploadResponse: Decodable {
    let id: String
    let shareURL: URL
    let downloadURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case shareURL = "share_url"
        case downloadURL = "download_url"
    }
}

enum CloudShareError: LocalizedError {
    case invalidBaseURL
    case missingToken
    case rejected(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Hosted sharing is not set up. Enter your share Worker URL and upload token in Settings > Cloud."
        case .missingToken: "Add the upload token in Cloud settings."
        case let .rejected(status, message): "Upload failed (\(status)): \(message)"
        case .invalidResponse: "The cloud returned an invalid response."
        }
    }
}

final class CloudShareService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Accepts an https share URL, or plain http only for a local `wrangler dev` server.
    static func validatedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http" where host == "localhost" || host == "127.0.0.1": return url
        default: return nil
        }
    }

    @MainActor
    func upload(record: CaptureRecord, preferences: AppPreferences) async throws -> CloudUploadResponse {
        guard let baseURL = Self.validatedBaseURL(preferences.cloudBaseURL) else { throw CloudShareError.invalidBaseURL }
        guard !preferences.uploadToken.isEmpty else { throw CloudShareError.missingToken }
        let fileURL = FileManager.default.fileExists(atPath: record.fileURL.path) ? record.fileURL : record.thumbnailURL
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        let byteCount = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        var components = URLComponents(url: baseURL.appendingPathComponent("api/uploads"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: record.displayName)]
        guard let endpoint = components.url else { throw CloudShareError.invalidBaseURL }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(preferences.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType(for: fileURL), forHTTPHeaderField: "Content-Type")
        request.setValue(fileURL.pathExtension, forHTTPHeaderField: "X-File-Extension")
        request.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")

        // Stream from disk: recordings can be hundreds of megabytes.
        let (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else { throw CloudShareError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw CloudShareError.rejected(http.statusCode, String(data: responseData, encoding: .utf8) ?? "Unknown error")
        }
        return try JSONDecoder().decode(CloudUploadResponse.self, from: responseData)
    }

    @MainActor
    func update(
        id: String,
        password: ShareFieldChange<String>,
        expiresAt: ShareFieldChange<Date>,
        tags: [String],
        preferences: AppPreferences
    ) async throws {
        guard let baseURL = Self.validatedBaseURL(preferences.cloudBaseURL) else { throw CloudShareError.invalidBaseURL }
        guard !preferences.uploadToken.isEmpty else { throw CloudShareError.missingToken }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads/\(id)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(preferences.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(UpdatePayload(password: password, expiresAt: expiresAt, tags: tags))
        try await requireSuccess(for: request)
    }

    @MainActor
    func delete(id: String, preferences: AppPreferences) async throws {
        guard let baseURL = Self.validatedBaseURL(preferences.cloudBaseURL) else { throw CloudShareError.invalidBaseURL }
        guard !preferences.uploadToken.isEmpty else { throw CloudShareError.missingToken }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(preferences.uploadToken)", forHTTPHeaderField: "Authorization")
        try await requireSuccess(for: request)
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "mov": "video/quicktime"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }

    struct UpdatePayload: Encodable {
        let password: ShareFieldChange<String>
        let expiresAt: ShareFieldChange<Date>
        let tags: [String]

        enum CodingKeys: String, CodingKey { case password, expiresAt, tags }

        /// The Worker keeps a field that is absent and clears one that is `null`.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try password.encode(in: &container, forKey: .password)
            try expiresAt.encode(in: &container, forKey: .expiresAt)
            try container.encode(tags, forKey: .tags)
        }
    }

    private func requireSuccess(for request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudShareError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw CloudShareError.rejected(http.statusCode, String(data: data, encoding: .utf8) ?? "Unknown error")
        }
    }
}

/// An edit to one share setting: leave it as stored, remove it, or replace it.
enum ShareFieldChange<Value: Encodable & Equatable>: Equatable {
    case keep
    case clear
    case set(Value)

    func encode<Key: CodingKey>(in container: inout KeyedEncodingContainer<Key>, forKey key: Key) throws {
        switch self {
        case .keep: break
        case .clear: try container.encodeNil(forKey: key)
        case let .set(value): try container.encode(value, forKey: key)
        }
    }
}
