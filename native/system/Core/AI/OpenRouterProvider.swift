import Foundation
import os

/// Where Explain's OpenRouter messages are logged. Tests record them to check that no key is ever logged.
public protocol ExplainLog: Sendable {
    func record(_ message: String)
}

/// The unified log, subsystem `dev.subset.system`. Messages hold only System's own words and status codes: never a key,
/// the model ID the user entered, a request body, or OpenRouter's message text.
public struct SystemExplainLog: ExplainLog {
    private static let logger = Logger(subsystem: "dev.subset.system", category: "openrouter")

    public init() {}

    public func record(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
    }
}

/// OpenRouter's chat completions endpoint with the user's own key (SET-50). The request is the same `ExplainRequest`
/// Apple Intelligence gets, as its prompt text, in a JSON body with a JSON schema `response_format` matching
/// `Explanation`; the body (`body(for:)`) has the same bytes each time it is built, and the client sends exactly it, so
/// SET-160's send preview can show it. The key is read from the Keychain for each request and goes only into its
/// `Authorization` header.
public struct OpenRouterProvider: AIProvider {
    public static let defaultModel = "openrouter/auto"
    /// How `OpenRouterClient.failure(status:data:key:)` begins each answer outside 2xx, which OpenRouter received.
    static let answeredPrefix = "OpenRouter answered "
    /// The longest model ID accepted.
    static let modelLimit = 200

    private let keys: OpenRouterKeyStore
    public let model: String
    private let client: OpenRouterClient

    public init(keys: OpenRouterKeyStore, model: String, client: OpenRouterClient) {
        self.keys = keys
        self.model = Self.model(model)
        self.client = client
    }

    /// The model ID sent: what the user entered, without the whitespace around it, when it is a model ID
    /// (`isModelID(_:)`), otherwise `openrouter/auto`, so a key pasted there, alone or inside other text, is never
    /// sent, logged, or shown as the model.
    public static func model(_ entered: String) -> String {
        let model = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        return isModelID(model) ? model : defaultModel
    }

    /// Whether `text` is shaped like an OpenRouter model ID, `[~]author/model[:variant]` in letters, digits, `.`, `_`
    /// and `-`, at most `modelLimit` characters, with no `sk-or-` anywhere in it. Quotes, brackets, spaces and the
    /// like cannot wrap a key in one.
    public static func isModelID(_ text: String) -> Bool {
        text.count <= modelLimit && !looksLikeKey(text)
            && text.wholeMatch(of: /~?[A-Za-z0-9._\-]+\/[A-Za-z0-9._\-]+(:[A-Za-z0-9._\-]+)?/) != nil
    }

    /// Whether `text` holds an OpenRouter API key (`sk-or-`, in any case) anywhere in it, which no model ID does.
    public static func looksLikeKey(_ text: String) -> Bool {
        text.lowercased().contains("sk-or-")
    }

    /// Whether `text` holds `key` anywhere in it, in any case.
    public static func contains(key: String, in text: String) -> Bool {
        !key.isEmpty && text.lowercased().contains(key.lowercased())
    }

    /// Available while a key is stored; it is not read, and nothing is sent.
    public func availability() async -> AIAvailability {
        do {
            return try keys.containsKey() ? .availableOnOpenRouter : .noOpenRouterKey
        } catch {
            return .openRouterKeyUnreadable
        }
    }

    /// Before a request is built: available while a key is stored and the model ID does not hold it, so a body whose
    /// model would be the key is never previewed or sent. The key is read only to check that; nothing is sent.
    public func availabilityBeforeSending() async -> AIAvailability {
        let key: String?
        do {
            key = try keys.readKey()
        } catch {
            return .openRouterKeyUnreadable
        }
        guard let key else { return .noOpenRouterKey }
        return Self.contains(key: key, in: model) ? .openRouterModelHeldKey : .availableOnOpenRouter
    }

    /// Sends nothing when the key cannot be read or the model ID contains it (`ExplainError.unavailable`). An answer
    /// OpenRouter gave that is not an explanation, its status outside 2xx included, is `ExplainError.rejected`, so
    /// `ExplainCenter` knows the request reached it; a connection failure or timeout is `ExplainError.failed`.
    public func explain(_ request: ExplainRequest) async throws -> ExplanationDraft {
        let key: String?
        do {
            key = try keys.readKey()
        } catch {
            throw ExplainError.unavailable(.openRouterKeyUnreadable)
        }
        guard let key else { throw ExplainError.unavailable(.noOpenRouterKey) }
        // The key inside the model ID, however Settings came to keep it, the key replaced since availability was read
        // included: not sent in the body.
        guard !Self.contains(key: key, in: model) else { throw ExplainError.unavailable(.openRouterModelHeldKey) }
        let data: Data
        do {
            data = try await client.send(.chat(try body(for: request)), key: key)
        } catch let ExplainError.failed(message) where message.hasPrefix(Self.answeredPrefix) {
            throw ExplainError.rejected(message)
        }
        return try Self.draft(from: data, key: key)
    }

    /// The JSON body sent for `request`: its bytes are the same each time it is built.
    public func body(for request: ExplainRequest) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": ExplainPrompt.instructions],
                ["role": "user", "content": request.promptText]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "explanation", "strict": true, "schema": Self.schema]
            ],
            // Routes only to providers that honor the response format.
            "provider": ["require_parameters": true]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// `Explanation`'s schema: exactly its fields, each required, the two closed ones as their values, and the
    /// suggested origin as text or null. Limits are in the descriptions; `Explanation(validating:for:)` enforces them.
    static var schema: [String: Any] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        let properties: [ExplanationDraft.Key: [String: Any]] = [
            .summary: text("One or two plain sentences, at most \(Explanation.summaryLimit) characters"),
            .whatItIs: text("What the item is and what it does, in plain text"),
            .removalSafety: ["type": "string", "enum": RemovalSafety.allCases.map(\.rawValue)],
            .howToRemove: text("How to remove it properly, in plain text"),
            .confidence: ["type": "string", "enum": ExplanationConfidence.allCases.map(\.rawValue)],
            .suggestedOrigin: [
                "type": ["string", "null"],
                "description": "Only when an origin may be suggested: the app, tool, or vendor it most likely belongs to; "
                    + "otherwise null"
            ]
        ]
        return [
            "type": "object",
            "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) }),
            "required": ExplanationDraft.Key.allCases.map(\.rawValue),
            "additionalProperties": false
        ]
    }

    /// The draft in a chat completion: the first choice's message content, read as `ExplanationDraft(json:)`. An
    /// error, whether the answer's or the first choice's (which comes with `finish_reason` `error` and whatever content
    /// was generated before it), fails with OpenRouter's reason, and no content is read.
    static func draft(from data: Data, key: String) throws -> ExplanationDraft {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExplainError.invalidResponse("OpenRouter's answer is not a JSON object.")
        }
        if let error = object["error"] { throw failure(error, key: key) }
        guard let choices = object["choices"] as? [Any], let choice = choices.first as? [String: Any] else {
            throw ExplainError.invalidResponse("OpenRouter's answer has no message.")
        }
        let choiceError = choice["error"].flatMap { $0 is NSNull ? nil : $0 }
        if choiceError != nil || choice["finish_reason"] as? String == "error" { throw failure(choiceError, key: key) }
        guard let message = choice["message"] as? [String: Any] else {
            throw ExplainError.invalidResponse("OpenRouter's answer has no message.")
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw ExplainError.rejected("The model declined to explain this item.")
        }
        guard let content = message["content"] as? String else {
            throw ExplainError.invalidResponse("OpenRouter's answer has no content.")
        }
        return try ExplanationDraft(json: Data(content.utf8))
    }

    /// "OpenRouter could not answer: …", with OpenRouter's message as `OpenRouterClient.message(in:key:)` gives it.
    private static func failure(_ error: Any?, key: String) -> ExplainError {
        let message = error.flatMap { OpenRouterClient.message(in: $0, key: key) }
        return .rejected(OpenRouterClient.sentence("OpenRouter could not answer: \(message ?? "no reason given")"))
    }
}

/// Sends System's two OpenRouter requests: a chat completion and the key test. Each has a 30-second timeout, sends
/// `X-Title: Subset System` and no `HTTP-Referer`, follows no redirect (so the key is sent to OpenRouter only), keeps
/// no cookies or cache, and is tried once more, after a backoff, when OpenRouter answers 429 or 5xx. Any other
/// answer outside 2xx is reported with its status and OpenRouter's message.
public struct OpenRouterClient: Sendable {
    public static let chatURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// Describes the key without using it: no tokens, no data.
    public static let keyURL = URL(string: "https://openrouter.ai/api/v1/key")!
    public static let appTitle = "Subset System"
    public static let timeout: TimeInterval = 30
    /// The wait before the retry, unless OpenRouter's `Retry-After` asks for between 1 and `longestBackoff` seconds.
    static let backoff: Duration = .seconds(2)
    static let longestBackoff = 10
    static let messageLimit = 300

    public enum Request: Sendable {
        case chat(Data)
        case keyTest

        var url: URL {
            switch self {
            case .chat: OpenRouterClient.chatURL
            case .keyTest: OpenRouterClient.keyURL
            }
        }

        var name: String {
            switch self {
            case .chat: "chat completion"
            case .keyTest: "key test"
            }
        }
    }

    private let session: URLSession
    private let log: any ExplainLog
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `session` carries the requests; tests give one whose protocol classes answer them.
    public init(session: URLSession = OpenRouterClient.liveSession(), log: any ExplainLog = SystemExplainLog(),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.session = session
        self.log = log
        self.sleep = sleep
    }

    /// An ephemeral session with no cookies or cache, so nothing of a request or answer is written to disk.
    public static func liveSession() -> URLSession {
        URLSession(configuration: configuration(.ephemeral))
    }

    /// `base` with System's timeout and no cookie or URL cache.
    public static func configuration(_ base: URLSessionConfiguration) -> URLSessionConfiguration {
        base.timeoutIntervalForRequest = timeout
        base.timeoutIntervalForResource = timeout
        base.httpCookieStorage = nil
        base.httpShouldSetCookies = false
        base.urlCache = nil
        base.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return base
    }

    /// The request as sent: method, headers, and body. The key is only in `Authorization`.
    static func urlRequest(_ request: Request, key: String) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: timeout)
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(appTitle, forHTTPHeaderField: "X-Title")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if case let .chat(body) = request {
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = body
        } else {
            urlRequest.httpMethod = "GET"
        }
        return urlRequest
    }

    /// The body of OpenRouter's 2xx answer. A chat completion sends exactly the body it is given, the retry included.
    /// Throws `ExplainError.failed` with the status and OpenRouter's message, or with the timeout or connection
    /// failure; `CancellationError` when cancelled, before the request or its retry is sent, during the backoff, or
    /// while it is on its way.
    public func send(_ request: Request, key: String) async throws -> Data {
        let urlRequest = Self.urlRequest(request, key: key)
        for attempt in 1...2 {
            try Task.checkCancellation()
            log.record("OpenRouter \(request.name) sent" + (attempt == 1 ? "" : " again"))
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: urlRequest, delegate: NoRedirects())
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                log.record("OpenRouter \(request.name) timed out")
                throw ExplainError.failed("OpenRouter did not answer within \(Int(Self.timeout)) seconds. Try again.")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                log.record("OpenRouter \(request.name) could not connect (\(error.code.rawValue))")
                throw ExplainError.failed("Could not reach OpenRouter: \(Self.clean(error.localizedDescription, key: key)).")
            }
            guard let http = response as? HTTPURLResponse else {
                throw ExplainError.failed("OpenRouter's answer was not HTTP.")
            }
            let status = http.statusCode
            log.record("OpenRouter \(request.name) answered \(status)")
            if (200..<300).contains(status) { return data }
            if attempt == 1, status == 429 || (500..<600).contains(status) {
                let delay = Self.delay(retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                log.record("OpenRouter \(request.name) retried after \(delay.components.seconds) seconds")
                try await sleep(delay)
                continue
            }
            throw ExplainError.failed(Self.failure(status: status, data: data, key: key))
        }
        // The second attempt returns or throws.
        throw ExplainError.failed("OpenRouter did not answer.")
    }

    /// The backoff: `Retry-After` in whole seconds when it is between 1 and `longestBackoff`, otherwise `backoff`.
    static func delay(retryAfter: String?) -> Duration {
        guard let seconds = retryAfter.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              (1...longestBackoff).contains(seconds) else { return backoff }
        return .seconds(seconds)
    }

    /// "OpenRouter answered 401 (unauthorized): No auth credentials found."
    static func failure(status: Int, data: Data, key: String) -> String {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        let object = try? JSONSerialization.jsonObject(with: data)
        let message = (object as? [String: Any])?["error"].flatMap { Self.message(in: $0, key: key) }
        return sentence("OpenRouter answered \(status) (\(reason))" + (message.map { ": " + $0 } ?? ""))
    }

    /// `text` ending in one full stop, or in the question or exclamation mark it ends in.
    static func sentence(_ text: String) -> String {
        text.last.map { ".!?…".contains($0) } == true ? text : text + "."
    }

    /// The message of OpenRouter's error object, `{"error": {"code": 401, "message": "…"}}`, or the error when it is
    /// text, on one line, with the key removed before it is capped. It is shown, never sent or logged.
    static func message(in error: Any, key: String) -> String? {
        let text = (error as? [String: Any])?["message"] as? String ?? error as? String
        guard let text else { return nil }
        let line = clean(ExplainRequest.oneLine(text), key: key).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > messageLimit ? String(line.prefix(messageLimit - 1)) + "…" : line
    }

    /// `text` with the key removed, should an answer or error ever repeat it.
    static func clean(_ text: String, key: String) -> String {
        text.replacingOccurrences(of: key, with: "[key]")
    }
}

/// Refuses every redirect, so the key's header is never sent anywhere but OpenRouter.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest) async -> URLRequest? {
        nil
    }
}
