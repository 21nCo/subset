import Foundation
import Observation

/// Identifies an item to explain across samples and scans: a group's or process's identity, or a scanned path.
public struct ExplainKey: Hashable, Sendable {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }
}

/// The chosen provider's availability as Settings shows it, from its latest read.
public enum AvailabilityStatus: Equatable, Sendable {
    /// The latest read has not answered yet.
    case checking
    case read(AIAvailability)
    /// The latest read did not answer within this many seconds.
    case noAnswer(seconds: Int64)

    public var availability: AIAvailability? {
        if case let .read(availability) = self { availability } else { nil }
    }
}

/// Where explaining one item stands.
public enum ExplainState: Equatable, Sendable {
    /// No provider is chosen, so Explain asks the user to choose one.
    case needsProvider
    /// Not asked yet with the chosen provider.
    case idle
    case working(ExplainRequest)
    case explained(Explanation, ExplainRequest)
    /// The provider cannot answer now; nothing was sent.
    case unavailable(AIAvailability)
    case failed(String, ExplainRequest)
    /// The item left the sample or scan before its request was built; nothing was sent.
    case gone
}

/// The Explain setting and each item's explanation. Nothing is sent until the user picks a provider (`choice` starts
/// as `.none`, and with `.none` no provider is made or called). Explanations are kept in memory for the session, per
/// provider and item; a failed or unavailable one can be asked again. A provider that does not answer in time is
/// given up on, so an item is never left being explained. Changing the provider ends the work begun with the one
/// before: it is cancelled, nothing it had not sent yet is sent, and nothing it answers is kept, even when the user
/// picks that provider again before it finishes.
@MainActor
@Observable
public final class ExplainCenter {
    public var choice: AIProviderChoice {
        didSet {
            guard choice != oldValue else { return }
            defaults.set(choice.rawValue, forKey: Self.choiceKey)
            selection += 1
            for cancel in pending.values { cancel() }
            pending = [:]
            states = states.filter { _, state in
                if case .working = state { false } else { true }
            }
            availabilityStatus = nil
        }
    }
    /// Sends folder names deeper than the first level under `~` instead of placeholders. Off by default.
    public var sendFolderNames: Bool {
        didSet { defaults.set(sendFolderNames, forKey: Self.sendFolderNamesKey) }
    }
    /// The chosen provider's availability from its latest read, which may still be checking or may not have answered
    /// in time; `nil` before any read and for `.none`.
    public private(set) var availabilityStatus: AvailabilityStatus?
    /// The chosen provider's availability when the latest read answered.
    public var availability: AIAvailability? { availabilityStatus?.availability }
    private var states: [StateKey: ExplainState] = [:]
    /// Counts availability reads, so only the latest one is shown.
    @ObservationIgnored private var availabilityReads = 0
    /// Counts provider changes, so work begun before the latest one changes nothing.
    @ObservationIgnored private var selection = 0
    /// Cancels each availability read and answer in flight, by when it began.
    @ObservationIgnored private var pending: [Int: @Sendable () -> Void] = [:]
    @ObservationIgnored private var pendingCount = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeProvider: @MainActor (AIProviderChoice) -> (any AIProvider)?
    @ObservationIgnored private let baseRedactor: ExplainRedactor
    @ObservationIgnored private let availabilityTimeout: Duration
    @ObservationIgnored private let answerTimeout: Duration

    static let choiceKey = "explainProvider"
    static let sendFolderNamesKey = "explainSendFolderNames"

    private struct StateKey: Hashable {
        let choice: AIProviderChoice
        let item: ExplainKey
    }

    /// `availabilityTimeout` and `answerTimeout` bound how long the provider may take to say whether it is available
    /// and to answer.
    public init(defaults: UserDefaults = .standard, redactor: ExplainRedactor,
                provider: @escaping @MainActor (AIProviderChoice) -> (any AIProvider)? = ExplainCenter.liveProvider,
                availabilityTimeout: Duration = .seconds(15), answerTimeout: Duration = .seconds(90)) {
        self.defaults = defaults
        baseRedactor = redactor
        makeProvider = provider
        self.availabilityTimeout = availabilityTimeout
        self.answerTimeout = answerTimeout
        choice = defaults.string(forKey: Self.choiceKey).flatMap(AIProviderChoice.init(rawValue:)) ?? .none
        sendFolderNames = defaults.bool(forKey: Self.sendFolderNamesKey)
    }

    /// This Mac's account, with placeholders keyed for this session.
    public static func live() -> ExplainCenter {
        ExplainCenter(redactor: .live(sendFolderNames: false, key: ExplainRedactor.sessionKey()))
    }

    public static func liveProvider(_ choice: AIProviderChoice) -> (any AIProvider)? {
        switch choice {
        case .none: nil
        case .appleIntelligence: AppleIntelligenceProvider()
        }
    }

    /// Redacts with the current **Send folder names** setting.
    public var redactor: ExplainRedactor { baseRedactor.sendingFolderNames(sendFolderNames) }

    public func state(for item: ExplainKey) -> ExplainState {
        guard choice != .none else { return .needsProvider }
        return states[StateKey(choice: choice, item: item)] ?? .idle
    }

    /// Reads the chosen provider's availability, for Settings, each time it is shown, when the provider changes, and
    /// when the user checks again. A read that a later one overtakes is not shown.
    public func refreshAvailability() async {
        guard choice != .none, let provider = makeProvider(choice) else { return }
        _ = await readAvailability(of: provider, in: selection)
    }

    /// `provider`'s availability, or `nil` when it does not answer in time. Settings shows it as checking while it is
    /// read, then what it answered or that it did not answer in time, only while no later read has started and the
    /// provider has not changed since `selection`, so a slow read never replaces a newer one.
    private func readAvailability(of provider: any AIProvider, in selection: Int) async -> AIAvailability? {
        availabilityReads += 1
        let read = availabilityReads
        availabilityStatus = .checking
        let availability: AIAvailability?
        do {
            let timeout = availabilityTimeout
            availability = try await untilProviderChanges {
                try await answer(within: timeout, { await provider.availability() })
            }
        } catch {
            // Cancelled, as when Settings closes: not a status; the next read shows one.
            if selection == self.selection, read == availabilityReads { availabilityStatus = nil }
            return nil
        }
        if selection == self.selection, read == availabilityReads {
            availabilityStatus = availability.map(AvailabilityStatus.read) ?? .noAnswer(seconds: availabilityTimeout.components.seconds)
        }
        return availability
    }

    /// Explains an item with the chosen provider, building its request with the current redactor. Does nothing without
    /// a provider, while the item is being explained, or once it has been. Returns when the answer is in. When the
    /// user changes the provider meanwhile, even back to this one, the work is cancelled, the request is not sent if it
    /// has not been yet, no answer is kept, and the item can be explained again at once; when
    /// the user changes **Send folder names** before it is sent, it is built again with the setting as it is then. When
    /// the provider does not say in time whether it is available, or does not answer in time, the item fails and can be
    /// asked again.
    public func explain(_ item: ExplainKey, request build: (ExplainRedactor) -> ExplainRequest?) async {
        let choice = self.choice
        let selection = self.selection
        let key = StateKey(choice: choice, item: item)
        switch states[key] {
        case .working?, .explained?: return
        default: break
        }
        guard choice != .none, let provider = makeProvider(choice) else { return }
        let sendFolderNames = self.sendFolderNames
        guard var request = build(redactor) else {
            states[key] = .gone
            return
        }
        states[key] = .working(request)
        let read = await readAvailability(of: provider, in: selection)
        // The provider changed meanwhile: this item's state is no longer this call's (a new request may have begun).
        guard selection == self.selection else { return }
        guard let availability = read else {
            states[key] = .failed(Self.late(choice, availabilityTimeout) + " Nothing was sent.", request)
            return
        }
        guard availability.isAvailable else {
            states[key] = .unavailable(availability)
            return
        }
        // Built with the setting the user has now, so a folder name is never sent once they turn it off.
        if sendFolderNames != self.sendFolderNames {
            guard let rebuilt = build(redactor) else {
                states[key] = .gone
                return
            }
            request = rebuilt
            states[key] = .working(request)
        }
        let outcome: ExplainState?
        do {
            let sent = request
            let timeout = answerTimeout
            let draft = try await untilProviderChanges { try await answer(within: timeout, { try await provider.explain(sent) }) }
            if let draft {
                outcome = .explained(try Explanation(validating: draft, for: request), request)
            } else {
                outcome = .failed(Self.late(choice, answerTimeout), request)
            }
        } catch let ExplainError.unavailable(availability) {
            outcome = .unavailable(availability)
        } catch let error as ExplainError {
            outcome = .failed(error.message, request)
        } catch is CancellationError {
            outcome = nil
        } catch {
            outcome = .failed(error.localizedDescription, request)
        }
        guard selection == self.selection else { return }
        states[key] = outcome
    }

    /// `operation`'s result, run so that changing the provider cancels it, as cancelling the caller does.
    private func untilProviderChanges<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T?
    ) async throws -> T? {
        let task = Task { try await operation() }
        pendingCount += 1
        let id = pendingCount
        pending[id] = { task.cancel() }
        defer { pending[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func late(_ choice: AIProviderChoice, _ timeout: Duration) -> String {
        "\(choice.title) did not answer within \(timeout.components.seconds) seconds. Try again."
    }
}

/// `operation`'s result, or `nil` when it takes longer than `timeout`; it is cancelled then, and one that ignores
/// cancellation is left to finish unobserved, so a provider that never answers cannot hold its caller.
func answer<T: Sendable>(within timeout: Duration,
                         _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard race.begin(continuation) else { return }
            race.add(Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            })
            race.add(Task {
                try? await Task.sleep(for: timeout)
                race.finish(.success(nil))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The first of an operation's result, its timeout, and its caller's cancellation; the tasks still running then are
/// cancelled.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, any Error>?
    private var tasks: [Task<Void, Never>] = []
    /// The outcome when it came before `begin`, such as a cancellation.
    private var early: Result<T?, any Error>?
    private var finished = false

    /// Whether the race starts: not when it was decided (cancelled) before.
    func begin(_ continuation: CheckedContinuation<T?, any Error>) -> Bool {
        lock.lock()
        let early = self.early
        if early == nil { self.continuation = continuation }
        lock.unlock()
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        let finished = self.finished
        if !finished { tasks.append(task) }
        lock.unlock()
        if finished { task.cancel() }
    }

    func finish(_ outcome: Result<T?, any Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = []
        if continuation == nil { early = outcome }
        lock.unlock()
        for task in tasks { task.cancel() }
        continuation?.resume(with: outcome)
    }
}
