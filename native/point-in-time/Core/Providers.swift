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
///
/// `Process` makes the child the leader of its own process group, so the signals go to the group: whatever the child
/// started (the native binary behind an npm launcher, say) is stopped with it. When the child exits, anything it left
/// running in its group is killed at once, and its output is not waited on for more than a few seconds. A group is
/// signaled only through `children`, which stops signaling it once its leader's exit is reported, so a group ID that has
/// been reused is never signaled. Each output stream is capped at `outputLimit` bytes; a child that writes more is
/// stopped and the run fails, as it does when `check` returns an error for a line of standard output.
enum ProcessRunner {
    static let outputLimit = 2 << 20

    static func run(_ executable: URL, _ arguments: [String], stdin: Data, directory: URL, environment: [String: String],
                    timeout: TimeInterval, children: ChildProcesses = .shared, outputLimit: Int = outputLimit,
                    check: (@Sendable (Data) -> ProviderError?)? = nil) async throws -> ProcessOutput {
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
            group.enter()
            group.enter()
            process.terminationHandler = { process in
                let result: @Sendable () -> ProcessOutput = { ProcessOutput(status: process.terminationStatus, stdout: out.value, stderr: err.value) }
                children.exited(group: process.processIdentifier)
                group.notify(queue: .global()) { finish.resume(.success(result())) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish.resume(.success(result())) }
            }
            do {
                try children.launch(process)
            } catch {
                group.leave()
                group.leave()
                finish.resume(.failure(ProviderError.process("Could not start \(executable.lastPathComponent): \(error.localizedDescription)")))
                return
            }
            let pid = process.processIdentifier
            let fail: @Sendable (ProviderError) -> Void = { error in if finish.resume(.failure(error)) { stopGroup(pid, children) } }
            let streams: [(Pipe, DataBox, (@Sendable (Data) -> ProviderError?)?)] = [(output, out, check), (errors, err, nil)]
            // Read as data arrives rather than blocking a thread until the output closes.
            for (pipe, box, check) in streams {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else {
                        handle.readabilityHandler = nil
                        group.leave()
                        return
                    }
                    guard box.append(chunk, limit: outputLimit) else {
                        return fail(.process("\(executable.lastPathComponent) wrote more than \(outputLimit) bytes of output"))
                    }
                    if let check, let error = box.newLines().lazy.compactMap(check).first { fail(error) }
                }
            }
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { fail(.timedOut(timeout)) }
        }
    }

    /// SIGTERM to the process group led by `pid`, then SIGKILL two seconds later unless its leader has exited by then.
    private static func stopGroup(_ pid: pid_t, _ children: ChildProcesses) {
        children.signal(group: pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { children.signal(group: pid, SIGKILL) }
    }
}

/// The process groups and request folders the providers have open, so that quitting the app stops and removes them
/// rather than leaving Codex running on the subscription, or its prompt and answer in the temporary folder.
///
/// A group is signaled only while its leader's exit has not been reported: once the leader is reaped and the group is
/// empty, the system may give its ID to someone else's group. While any member is left, the ID is not reused, so the
/// group is killed at once when its leader's exit is reported.
public final class ChildProcesses: @unchecked Sendable {
    public static let shared = ChildProcesses()

    private let lock = NSLock()
    private var groups: Set<pid_t> = []
    private var folders: Set<URL> = []
    private var stopped = false

    public init() {}

    /// Starts `process` and tracks its group, unless the app is quitting. The lock is held across the start, so even a
    /// child that exits at once has its exit reported after it is tracked.
    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !stopped else { throw ProviderError.process("pointInTime is quitting") }
            try process.run()
            groups.insert(process.processIdentifier)
        }
    }

    /// Signals the group led by `pid` if its leader's exit has not been reported; otherwise does nothing.
    func signal(group pid: pid_t, _ signal: Int32) {
        lock.withLock { if groups.contains(pid) { kill(-pid, signal) } }
    }

    /// The leader of `pid`'s group exited: whatever it left running is killed now, and the group is not signaled again.
    func exited(group pid: pid_t) {
        lock.withLock { if groups.remove(pid) != nil { kill(-pid, SIGKILL) } }
    }

    func add(folder url: URL) -> Bool { lock.withLock { stopped ? false : folders.insert(url).inserted } }
    func remove(folder url: URL) { _ = lock.withLock { folders.remove(url) } }

    /// For quitting: SIGTERM to every group, SIGKILL to those whose leader is still running after `grace`, and every
    /// folder removed, before returning. Nothing is started afterwards.
    public func stopAll(grace: TimeInterval = 1) {
        let (groups, folders) = lock.withLock {
            stopped = true
            defer { self.folders = [] }
            return (self.groups, self.folders)
        }
        for pid in groups { signal(group: pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, lock.withLock({ !self.groups.isDisjoint(with: groups) }) { usleep(20_000) }
        for pid in groups { signal(group: pid, SIGKILL) }
        for url in folders { try? FileManager.default.removeItem(at: url) }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var lineStart = 0

    /// Keeps `chunk`, or nothing and returns false when that would take the stream past `limit` bytes.
    func append(_ chunk: Data, limit: Int) -> Bool {
        lock.withLock {
            guard data.count + chunk.count <= limit else { return false }
            data.append(chunk)
            return true
        }
    }

    /// The lines completed since the last call, without their newlines.
    func newLines() -> [Data] {
        lock.withLock {
            guard let end = data[lineStart...].lastIndex(of: 0x0A) else { return [] }
            defer { lineStart = end + 1 }
            return data[lineStart..<end].split(separator: 0x0A).map { Data($0) }
        }
    }

    var value: Data { lock.withLock { data } }
}

/// Resumes a continuation once; later results are dropped.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T, Error>?

    /// True when this call resumed the continuation.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        let continuation = lock.withLock { defer { self.continuation = nil }; return self.continuation }
        continuation?.resume(with: result)
        return continuation != nil
    }
}

/// A new folder only this user can read, removed by `remove()` or when the app quits.
struct PrivateDirectory {
    let url: URL
    private let children: ChildProcesses

    init(prefix: String, children: ChildProcesses) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        self.children = children
        guard children.add(folder: url) else { throw ProviderError.process("pointInTime is quitting") }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            children.remove(folder: url)
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        children.remove(folder: url)
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
///
/// The prompt asks Codex not to use tools, but that is not what keeps it to the request: `exec` runs with every feature
/// that gives the model a tool turned off, and with web search off. A codex that does not know one of them refuses to
/// start, so nothing is sent. Its `--json` events are checked as they arrive: any item other than the answer, its
/// reasoning, or a notice from Codex itself stops the run and the answer is discarded.
public struct CodexCLI: ClassificationProvider {
    public static let defaultTimeout: TimeInterval = 180

    public let name = "chatgpt-codex"
    /// `codex exec` runs Codex's default model; the user's config, which could choose another, is not loaded.
    public let model = "codex-default"
    public let executable: URL
    public let searchPath: String
    public let timeout: TimeInterval
    let children: ChildProcesses
    private let baseEnvironment: [String: String]

    /// `searchPath` is the `PATH` the child gets. The binary's own folder is put first, so a launcher script finds the
    /// runtime installed beside it (for example `node` in the same version manager folder). `environment` is what the
    /// child inherits, less what could make Codex use something other than the ChatGPT sign-in.
    public init(executable: URL, searchPath: String?, timeout: TimeInterval = CodexCLI.defaultTimeout, children: ChildProcesses = .shared,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        baseEnvironment = environment
        let folder = executable.deletingLastPathComponent().path
        self.searchPath = ([folder] + (searchPath ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init))
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        self.timeout = timeout
        self.children = children
    }

    /// The features that give the model a tool: a shell, images, apps and plugins, a browser or the computer, other
    /// agents, goals, image generation, and hooks.
    static let disabledFeatures = ["shell_tool", "view_image", "apps", "plugins", "browser_use", "computer_use", "multi_agent", "goals",
                                   "image_generation", "hooks"]
    /// The `--json` items a classification may produce.
    static let allowedItems: Set<String> = ["agent_message", "reasoning", "error"]

    public static func execArguments(workingDirectory: URL, schema: URL, output: URL) -> [String] {
        ["exec", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--sandbox", "read-only", "--json"]
            + disabledFeatures.flatMap { ["--disable", $0] }
            + ["-c", "web_search=\"disabled\"", "--color", "never", "--cd", workingDirectory.path, "--output-schema", schema.path,
               "-o", output.path, "-"]
    }

    /// Nil when `line` is a `--json` event a classification may produce.
    static func refusedEvent(_ line: Data) -> ProviderError? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], event["type"] is String else {
            return .invalidResponse("codex exec printed something other than its events")
        }
        guard let item = event["item"] else { return nil }
        let type = (item as? [String: Any])?["type"] as? String ?? "unknown"
        return allowedItems.contains(type) ? nil : .invalidResponse("Codex went beyond the request (\(type)), so its answer was discarded")
    }

    public func loginStatus() async -> CodexLoginStatus {
        let folder: PrivateDirectory
        do { folder = try PrivateDirectory(prefix: "pointInTime-codex", children: children) } catch { return .unavailable(error.localizedDescription) }
        defer { folder.remove() }
        do {
            let result = try await ProcessRunner.run(executable, ["login", "status"], stdin: Data(), directory: folder.url,
                                                     environment: environment, timeout: 30, children: children)
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
        let folder = try PrivateDirectory(prefix: "pointInTime-codex", children: children)
        defer { folder.remove() }
        // Codex works in `work`, which stays empty; the schema and answer sit beside it.
        let work = folder.url.appendingPathComponent("work", isDirectory: true)
        let schemaFile = folder.url.appendingPathComponent("schema.json"), answerFile = folder.url.appendingPathComponent("answer.json")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: schemaFile.path, contents: Data(schema.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ProviderError.process("Could not write the answer schema")
        }
        let result = try await ProcessRunner.run(executable, Self.execArguments(workingDirectory: work, schema: schemaFile, output: answerFile),
                                                 stdin: Data(prompt.utf8), directory: work, environment: environment, timeout: timeout,
                                                 children: children, check: Self.refusedEvent)
        guard result.status == 0 else {
            if String(decoding: result.stderr, as: UTF8.self).contains("Unknown feature flag") {
                throw ProviderError.process("This codex cannot turn its tools off, so nothing was sent. Update Codex.")
            }
            throw ProviderError.process("codex exec exited with status \(result.status)")
        }
        // The whole event stream, including what arrived after the run ended, and a finished turn.
        let events = result.stdout.split(separator: 0x0A).map { Data($0) }
        if let error = events.lazy.compactMap(Self.refusedEvent).first { throw error }
        guard events.contains(where: { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["type"] as? String == "turn.completed" }) else {
            throw ProviderError.invalidResponse("codex exec did not finish its turn")
        }
        guard let answer = try? String(contentsOf: answerFile, encoding: .utf8), !answer.isEmpty else {
            throw ProviderError.invalidResponse("codex exec wrote no answer")
        }
        return answer
    }

    /// `CODEX_` and `OPENAI_` variables can choose an API key, another account, or another endpoint (`login status`
    /// ignores `CODEX_API_KEY` while `exec` uses it), so the child gets none of them except these two.
    static let keptCodexVariables: Set<String> = ["CODEX_HOME", "CODEX_CA_CERTIFICATE"]

    private var environment: [String: String] {
        var environment = baseEnvironment.filter { name, _ in
            let upper = name.uppercased()
            return Self.keptCodexVariables.contains(upper) || !(upper.hasPrefix("CODEX_") || upper.contains("OPENAI_"))
        }
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
