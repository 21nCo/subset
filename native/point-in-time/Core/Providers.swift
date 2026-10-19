import Foundation

// MARK: Process

/// What a finished child process wrote.
struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs a child process with its input on stdin, and stops it at a deadline: SIGTERM first, SIGKILL two seconds later.
/// A timed-out run throws at the deadline without waiting for the child's output to close.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], stdin: Data, directory: URL, environment: [String: String],
                    timeout: TimeInterval) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A child that exits before reading its input must not raise SIGPIPE in this app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let finish = OneShot<ProcessOutput>()
        return try await withCheckedThrowingContinuation { continuation in
            finish.continuation = continuation
            let group = DispatchGroup()
            let out = DataBox(), err = DataBox()
            // Read as data arrives rather than blocking a thread until the output closes.
            for (pipe, box) in [(output, out), (errors, err)] {
                group.enter()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        group.leave()
                    } else {
                        box.append(chunk)
                    }
                }
            }
            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    finish.resume(.success(ProcessOutput(status: process.terminationStatus, stdout: out.value, stderr: err.value)))
                }
            }
            do {
                try process.run()
            } catch {
                for pipe in [output, errors] { pipe.fileHandleForReading.readabilityHandler = nil }
                finish.resume(.failure(ProviderError.process("Could not start \(executable.lastPathComponent): \(error.localizedDescription)")))
                return
            }
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // Also ends the wait when the child exited but something it started still holds its output open.
                finish.resume(.failure(ProviderError.timedOut(timeout)))
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var value: Data { lock.withLock { data } }
}

/// Resumes a continuation once; later results are dropped.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T, Error>?

    func resume(_ result: Result<T, Error>) {
        let continuation = lock.withLock { defer { self.continuation = nil }; return self.continuation }
        continuation?.resume(with: result)
    }
}

/// A new folder only this user can read, removed by `remove()`.
struct PrivateDirectory {
    let url: URL

    init(prefix: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: ChatGPT subscription through the Codex CLI

public enum CodexLoginStatus: Equatable, Sendable {
    /// Signed in with a ChatGPT account, the only sign-in this provider uses.
    case signedIn
    /// Signed in some other way, such as an API key; nothing is sent then.
    case notChatGPT
    case signedOut
    case unavailable(String)
}

/// Classifies with the user's own `codex` binary and its ChatGPT sign-in. pointInTime never reads Codex's credential
/// files or calls ChatGPT itself: it checks `codex login status` and runs `codex exec` in an empty private folder,
/// without the user's Codex config or rules, with a read-only sandbox, the prompt on stdin, and a timeout.
public struct CodexCLI: ClassificationProvider {
    public static let defaultTimeout: TimeInterval = 180

    public let name = "chatgpt-codex"
    /// `codex exec` runs Codex's default model; the user's config, which could choose another, is not loaded.
    public let model = "codex-default"
    public let executable: URL
    public let searchPath: String
    public let timeout: TimeInterval

    /// `searchPath` is the `PATH` the child gets. The binary's own folder is put first, so a launcher script finds the
    /// runtime installed beside it (for example `node` in the same version manager folder).
    public init(executable: URL, searchPath: String?, timeout: TimeInterval = CodexCLI.defaultTimeout) {
        self.executable = executable
        let folder = executable.deletingLastPathComponent().path
        self.searchPath = ([folder] + (searchPath ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        self.timeout = timeout
    }

    public static func execArguments(workingDirectory: URL, schema: URL, output: URL) -> [String] {
        ["exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--sandbox", "read-only",
         "--color", "never", "--cd", workingDirectory.path, "--output-schema", schema.path, "-o", output.path, "-"]
    }

    public func loginStatus() async -> CodexLoginStatus {
        let folder: PrivateDirectory
        do { folder = try PrivateDirectory(prefix: "pointInTime-codex") } catch { return .unavailable(error.localizedDescription) }
        defer { folder.remove() }
        do {
            let result = try await ProcessRunner.run(executable, ["login", "status"], stdin: Data(), directory: folder.url,
                                                     environment: environment, timeout: 30)
            let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            guard result.status == 0 else {
                // Only Codex's own answer means signed out; any other failure (a missing runtime, say) is reported as is.
                return text.localizedCaseInsensitiveContains("not logged in")
                    ? .signedOut : .unavailable("codex login status exited with status \(result.status)")
            }
            // An API-key sign-in also exits 0, and its status line shows part of the key, so the text is never shown.
            return text.contains("Logged in using ChatGPT") ? .signedIn : .notChatGPT
        } catch {
            return .unavailable(String(describing: error))
        }
    }

    public func prepare() async throws {
        switch await loginStatus() {
        case .signedIn: break
        case .signedOut: throw ProviderError.notSignedIn
        case .notChatGPT: throw ProviderError.notChatGPT
        case .unavailable(let message): throw ProviderError.process(message)
        }
    }

    public func complete(prompt: String, schema: String) async throws -> String {
        let folder = try PrivateDirectory(prefix: "pointInTime-codex")
        defer { folder.remove() }
        // Codex works in `work`, which stays empty; the schema and answer sit beside it.
        let work = folder.url.appendingPathComponent("work", isDirectory: true)
        let schemaFile = folder.url.appendingPathComponent("schema.json"), answerFile = folder.url.appendingPathComponent("answer.json")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: schemaFile.path, contents: Data(schema.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ProviderError.process("Could not write the answer schema")
        }
        let result = try await ProcessRunner.run(executable, Self.execArguments(workingDirectory: work, schema: schemaFile, output: answerFile),
                                                 stdin: Data(prompt.utf8), directory: work, environment: environment, timeout: timeout)
        guard result.status == 0 else { throw ProviderError.process("codex exec exited with status \(result.status)") }
        guard let answer = try? String(contentsOf: answerFile, encoding: .utf8), !answer.isEmpty else {
            throw ProviderError.invalidResponse("codex exec wrote no answer")
        }
        return answer
    }

    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// The `PATH` of the user's login shell, which is where Terminal would find `codex`.
    public static func loginShellPATH(timeout: TimeInterval = 10) async -> String? {
        let shell = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let marker = "__POINT_IN_TIME_PATH__"
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: shell), ["-l", "-c", "printf '\(marker)%s' \"$PATH\""],
                                                        stdin: Data(), directory: FileManager.default.homeDirectoryForCurrentUser,
                                                        environment: ["HOME": NSHomeDirectory()], timeout: timeout),
              result.status == 0 else { return nil }
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let path = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The first executable `codex` in `path`.
    public static func locate(in path: String) -> URL? {
        path.split(separator: ":").lazy.map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: OpenRouter key

/// Sends HTTP requests; tests replace it.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// An ephemeral session: no cookies, cache, or credential storage on disk.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 90) {
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

    public let name = "openrouter"
    public let model: String
    private let key: String
    private let transport: any HTTPTransport

    public init(key: String, model: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.key = key
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.isEmpty ? Self.defaultModel : model
        self.transport = transport
    }

    public func complete(prompt: String, schema: String) async throws -> String {
        let schemaObject = try JSONSerialization.jsonObject(with: Data(schema.utf8))
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "block_labels", "strict": true, "schema": schemaObject]],
            // Route only to providers that honor the response format.
            "provider": ["require_parameters": true]
        ]
        var request = authorized(Self.completionsURL)
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
        _ = try await send(authorized(Self.keyURL))
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
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
        case 429: throw ProviderError.rateLimited(retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 408, 500...: throw ProviderError.network("OpenRouter returned HTTP \(response.statusCode)")
        default: throw ProviderError.process("OpenRouter refused the request (HTTP \(response.statusCode))")
        }
    }
}
