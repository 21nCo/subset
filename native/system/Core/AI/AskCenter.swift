import Foundation
import Observation

/// What the send preview shows for an Ask request off this Mac: exactly the body that will be sent. Each preview built
/// is its own, so a Send from one withdrawn never sends another.
public struct AskSendPreview: Equatable, Sendable {
    public let provider: AIProviderChoice
    public let body: Data
    /// Never shown, stored or sent; minted as the preview is built, so it equals only itself.
    let id = UUID()

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Ask (SET-51): one question and up to `followUpLimit` follow-ups per thread, answered by the provider Explain uses,
/// with the read-only tools of `AskToolbox`. The thread is kept in memory only, and ends when the provider or **Send
/// folder names** changes, since a follow-up gives the provider the thread's earlier questions and answers. Nothing is
/// asked while no provider is chosen. As with Explain, until OpenRouter has answered a request whose body the user
/// confirmed this session (`ExplainCenter.sendConfirmed`, shared), each request to it waits for its own send preview,
/// and while Add Key or Remove Key runs none is sent. Each read of the OpenRouter key is one of the checks Explain's are
/// (SET-165): one that finds the key cannot be used, from the latest check, sets the choice back and says why, as
/// Explain's does, which begins a new thread; one a later check overtook fails only its own question, and changes no
/// provider and no thread. A question not answered within `timeout`, not counting the time a preview waits, fails and
/// can be asked again; Stop, or Cancel in the preview, ends it and keeps nothing of it.
@MainActor
@Observable
public final class AskCenter {
    public enum State: Equatable, Sendable {
        case working
        /// Waiting for the user to confirm the send preview; nothing of this request has been sent.
        case confirming(AskSendPreview)
        case answered(AskAnswer)
        case failed(String)
    }

    public struct Exchange: Identifiable, Equatable, Sendable {
        public let id: Int
        public let question: String
        public fileprivate(set) var state: State
        /// The tools the answer called, in order.
        public fileprivate(set) var tools: [AskToolRecord] = []
        /// Exactly the bodies sent off this Mac that the provider answered.
        public fileprivate(set) var sent: [Data] = []
    }

    public static let followUpLimit = 5
    public static let questionLimit = 500

    /// The thread, oldest first. Only its last exchange can be working, waiting for the preview, or failed.
    public private(set) var exchanges: [Exchange] = []
    /// Why the thread ended on its own; cleared by the next question.
    public private(set) var notice: String?

    @ObservationIgnored private let explain: ExplainCenter
    @ObservationIgnored private let source: AskSource
    @ObservationIgnored private var toolbox: AskToolbox
    @ObservationIgnored private let timeout: Duration
    /// The question running now; work and tool calls for any other are ignored.
    @ObservationIgnored private var question = 0
    @ObservationIgnored private var nextExchange = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// When the question running fails for lateness; `nil` while it waits for the send preview.
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var pending: (preview: AskSendPreview, continuation: CheckedContinuation<Void, any Error>)?

    static let providerChanged = "The AI provider changed, so a new thread began."
    static let folderNamesChanged = "Send folder names changed, so a new thread began."
    static let keyChanged = "The OpenRouter key changed while this question was asked, so nothing more was sent. Ask "
        + "again."

    public init(explain: ExplainCenter, source: AskSource, timeout: Duration = .seconds(120)) {
        self.explain = explain
        self.source = source
        self.timeout = timeout
        toolbox = AskToolbox(source: source, redactor: explain.redactor)
        explain.onWorkEnded = { [weak self] end in self?.workEnded(end) }
    }

    /// No provider is chosen, so Ask is off.
    public var needsProvider: Bool { explain.choice == .none }

    public var provider: AIProviderChoice { explain.choice }

    public var isBusy: Bool {
        switch exchanges.last?.state {
        case .working?, .confirming?: true
        default: false
        }
    }

    private var answered: [Exchange] {
        exchanges.filter { if case .answered = $0.state { true } else { false } }
    }

    /// How many more questions the thread takes: the first and `followUpLimit` follow-ups.
    public var questionsLeft: Int { max(0, Self.followUpLimit + 1 - answered.count) }

    public var canAsk: Bool { !needsProvider && !isBusy && questionsLeft > 0 }

    /// Asks `text` in the thread, and returns whether it was asked: not without a provider, while a question runs, once
    /// the thread is full, or when the question is empty or longer than `questionLimit`. A failed question before it is
    /// replaced.
    @discardableResult
    public func ask(_ text: String) -> Bool {
        let questionText = ExplainRequest.oneLine(text).trimmingCharacters(in: .whitespaces)
        guard canAsk, !questionText.isEmpty, questionText.count <= Self.questionLimit,
              let provider = explain.makeProvider(explain.choice) else { return false }
        if case .failed? = exchanges.last?.state { exchanges.removeLast() }
        notice = nil
        question += 1
        let question = question
        let prompt = AskPrompt(history: answered.compactMap { exchange in
            guard case let .answered(answer) = exchange.state else { return nil }
            return AskPrompt.Turn(question: exchange.question, answer: answer.text)
        }, question: questionText)
        nextExchange += 1
        exchanges.append(Exchange(id: nextExchange, question: questionText, state: .working))
        guard !explain.keyChanging(explain.choice) else {
            finish(question, .failed(ExplainCenter.keyChanging))
            return true
        }
        toolbox.begin(question, redactor: explain.redactor)
        let tools = toolbox.tools(for: question)
        let gate = AskSendGate(check: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.startCheck(question: question)
        }, confirm: { [weak self] body in
            guard let self else { throw CancellationError() }
            return try await self.confirm(body, question: question)
        }, answered: { [weak self] body, confirmed in
            await self?.answered(body, confirmed: confirmed, question: question)
        })
        deadline = .now + timeout
        work = Task { [weak self] in
            let outcome: Result<String, any Error>
            do { outcome = .success(try await provider.ask(prompt, tools: tools, gate: gate)) } catch {
                outcome = .failure(error)
            }
            self?.complete(question, outcome, from: provider)
        }
        watchdog = Task { [weak self] in await self?.watch(question) }
        return true
    }

    /// Ends the question running: nothing more is sent, and nothing of it is kept.
    public func stop() {
        guard isBusy else { return }
        end()
        exchanges.removeLast()
    }

    /// Ends the thread: the question running, if any, as `stop()` does, and every exchange; ids start again.
    public func newThread() {
        end()
        exchanges = []
        notice = nil
        toolbox = AskToolbox(source: source, redactor: explain.redactor)
    }

    /// Sends the body of `preview`, when it is still the one the question waits for.
    public func confirmSend(_ preview: AskSendPreview) {
        guard let pending, pending.preview == preview else { return }
        self.pending = nil
        pending.continuation.resume()
    }

    /// Cancel in the send preview: nothing is sent, and the question is not kept.
    public func cancelSend() {
        guard case .confirming? = exchanges.last?.state else { return }
        stop()
    }

    /// Shows what a citation selects; `false` when it is no longer in the sample or scan.
    @discardableResult
    public func select(_ target: AskTarget) -> Bool {
        source.select(target)
    }

    /// Waits for the question running to finish, for tests.
    func settled() async {
        await work?.value
        await watchdog?.value
    }

    // MARK: Running a question

    private func complete(_ question: Int, _ outcome: Result<String, any Error>, from provider: any AIProvider) {
        guard question == self.question, isBusy else { return }
        let state: State
        switch outcome {
        case let .success(text):
            do {
                state = .answered(try AskAnswer(validating: text, target: toolbox.target(for:)))
            } catch let error as ExplainError {
                state = .failed(error.message)
            } catch {
                state = .failed(error.localizedDescription)
            }
        case let .failure(refusal as AskKeyRefusal):
            if let message = explain.refused(refusal.availability, check: refusal.check, from: provider) {
                state = .failed(message)
            } else {
                // From the latest check: the choice was set back, which began a new thread; it says why.
                guard question == self.question, isBusy else {
                    if explain.choice != .openRouter, let reason = explain.notice { notice = reason }
                    return
                }
                state = .failed(ExplainError.unavailable(refusal.availability).message)
            }
        case let .failure(error as ExplainError):
            state = .failed(error.message)
        case .failure(is CancellationError):
            // Ended by Stop or a change, which say so themselves.
            return
        case let .failure(error):
            state = .failed(error.localizedDescription)
        }
        finish(question, state)
    }

    /// Keeps the question's outcome with the tools it called, and ends its work.
    private func finish(_ question: Int, _ state: State) {
        guard question == self.question, !exchanges.isEmpty else { return }
        exchanges[exchanges.count - 1].state = state
        exchanges[exchanges.count - 1].tools = toolbox.records
        self.question += 1
        toolbox.end()
        deadline = nil
        watchdog?.cancel()
        work = nil
    }

    /// Ends the question running: its work is cancelled, a preview it waits for sends nothing, and whatever it
    /// answers later is ignored.
    private func end() {
        question += 1
        toolbox.end()
        deadline = nil
        work?.cancel()
        watchdog?.cancel()
        work = nil
        if let pending {
            self.pending = nil
            pending.continuation.resume(throwing: CancellationError())
        }
    }

    /// Fails the question once `deadline` passes; the time it waits for the send preview does not count.
    private func watch(_ question: Int) async {
        while question == self.question, !Task.isCancelled {
            guard let deadline else {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            if ContinuousClock.now >= deadline {
                let late = "\(explain.choice.title) did not answer within \(timeout.components.seconds) seconds. Ask again."
                end()
                exchanges[exchanges.count - 1].state = .failed(late)
                return
            }
            try? await Task.sleep(until: deadline, clock: .continuous)
        }
    }

    /// Before the provider reads its key: a check shared with Explain's, not taken while the OpenRouter key is being
    /// changed.
    private func startCheck(question: Int) throws -> Int {
        guard question == self.question else { throw CancellationError() }
        guard !explain.keyChanging(explain.choice) else { throw ExplainError.failed(ExplainCenter.keyChanging) }
        return explain.startCheck()
    }

    /// Before a body is sent off this Mac: while no request the user confirmed has been answered this session, the
    /// question waits for its preview; nothing is sent while the OpenRouter key is being changed.
    private func confirm(_ body: Data, question: Int) async throws -> Bool {
        guard question == self.question else { throw CancellationError() }
        guard !explain.keyChanging(explain.choice) else { throw ExplainError.failed(ExplainCenter.keyChanging) }
        guard !explain.sendConfirmed else { return false }
        let preview = AskSendPreview(provider: explain.choice, body: body)
        exchanges[exchanges.count - 1].state = .confirming(preview)
        deadline = nil
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (preview, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let pending, pending.preview == preview else { return }
                self.pending = nil
                pending.continuation.resume(throwing: CancellationError())
            }
        }
        guard question == self.question else { throw CancellationError() }
        exchanges[exchanges.count - 1].state = .working
        deadline = .now + timeout
        return true
    }

    private func answered(_ body: Data, confirmed: Bool, question: Int) {
        if confirmed { explain.sendConfirmed = true }
        guard question == self.question else { return }
        exchanges[exchanges.count - 1].sent.append(body)
    }

    private func workEnded(_ end: ExplainCenter.WorkEnd) {
        switch end {
        case .providerChanged, .folderNamesChanged:
            let hadThread = !exchanges.isEmpty
            newThread()
            if hadThread { notice = end == .providerChanged ? Self.providerChanged : Self.folderNamesChanged }
        case .keyChanging:
            guard isBusy else { return }
            self.end()
            exchanges[exchanges.count - 1].state = .failed(Self.keyChanged)
        }
    }
}
