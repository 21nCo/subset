import Foundation

/// Sends HTTP requests; tests replace it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral session: no cookies, cache, or credential storage on disk.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = OpenRouterClient.timeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.network("Not an HTTP response") }
        return (data, http)
    }
}

/// Classifies through OpenRouter's chat completions with the user's own key and a JSON-schema response format.
public struct OpenRouterClient: ClassificationProvider {
    /// Supports strict JSON-schema output; the user can choose any other OpenRouter model ID that does.
    public static let defaultModel = "openai/gpt-4.1-mini"
    static let completionsURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    /// How long a request may wait for data, set on each request as well as on the default session.
    public static let timeout: TimeInterval = 90

    public let name = "openrouter"
    public let model: String
    private let key: @Sendable () throws -> String?
    private let transport: any HTTPTransport

    public init(key: String, model: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(model: model, transport: transport) { key }
    }

    /// Reads the key from `keychain` only when a request is about to go, not when the client is set up.
    public init(keychain: KeychainSecret, model: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(model: model, transport: transport) { try keychain.read() }
    }

    private init(model: String, transport: any HTTPTransport, key: @escaping @Sendable () throws -> String?) {
        self.key = key
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.isEmpty ? Self.defaultModel : model
        self.transport = transport
    }

    public func complete(prompt: String, schema: String) async throws -> String {
        let key = try readKey()
        let schemaObject = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "block_labels", "strict": true, "schema": schemaObject]],
            // Route only to providers that honor the response format.
            "provider": ["require_parameters": true]
        ]
        var request = authorized(Self.completionsURL, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderError.invalidResponse("OpenRouter returned no message")
        }
        return content
    }

    /// Checks the key against OpenRouter's key endpoint without sending any activity.
    public func testKey() async throws {
        _ = try await send(authorized(Self.keyURL, key: try readKey()))
    }

    private func readKey() throws -> String {
        let stored: String?
        do {
            stored = try key()
        } catch {
            throw ProviderError.notConfigured("The OpenRouter key could not be read from the Keychain (\(error)).")
        }
        guard let stored, !stored.isEmpty else { throw ProviderError.notConfigured("No OpenRouter key is saved in the Keychain.") }
        return stored
    }

    /// The wait a Retry-After value asks for, in seconds or until an HTTP date, never negative; nil when it is neither.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds.isFinite ? max(0, seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    private func authorized(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw ProviderError.timedOut(request.timeoutInterval)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.unauthorized("OpenRouter rejected the key (HTTP \(response.statusCode))")
        case 402: throw ProviderError.unauthorized("OpenRouter reports the key has no credits left (HTTP 402)")
        case 429: throw ProviderError.rateLimited(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 408, 500...: throw ProviderError.network("OpenRouter returned HTTP \(response.statusCode)")
        default: throw ProviderError.process("OpenRouter refused the request (HTTP \(response.statusCode))")
        }
    }
}
