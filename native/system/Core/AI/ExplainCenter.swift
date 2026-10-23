import Foundation
import Observation
import os

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
    /// Waiting for the user to confirm the send preview, before the first request of the session to a provider off
    /// this Mac; nothing has been sent.
    case confirming(SendPreview)
    case explained(Explanation, ExplainRequest)
    /// The provider cannot answer now; nothing was sent.
    case unavailable(AIAvailability)
    case failed(String, ExplainRequest)
    /// The item left the sample or scan before its request was built; nothing was sent.
    case gone
}

/// What the send preview shows: exactly what the provider will send for the request.
public struct SendPreview: Equatable, Sendable {
    public let provider: AIProviderChoice
    /// The body as sent, byte for byte.
    public let text: String
    public let request: ExplainRequest
}

/// The Explain setting and each item's explanation. Nothing is sent until the user picks a provider (`choice` starts
/// as `.none`, and with `.none` no provider is made or called). Explanations are kept in memory for the session, per
/// provider and item; a failed or unavailable one can be asked again. A provider that does not answer in time is
/// given up on, so an item is never left being explained. Changing the provider ends the work begun with the one
/// before: it is cancelled, nothing it had not sent yet is sent, and nothing it answers is kept, even when the user
/// picks that provider again before it finishes. Before the first request of the session to a provider off this Mac
/// (OpenRouter), the item waits while the user reviews exactly what will be sent and confirms it, and that request is the
/// session's first: every other request to the provider waits until it has ended. Once it has gone out, no preview is
/// shown again this session; when it ends before it went out (the key could not be read, it was cancelled or timed out,
/// **Send folder names** changed, or the provider changed), the preview is still required, and the items that waited
/// for it are previewed instead. Each attempt to send a request, the retry included, goes out only while **Send folder
/// names** is as it was when the request was built.
@MainActor
@Observable
public final class ExplainCenter {
    /// Changed through `choose(_:)`, which refuses OpenRouter while no key is stored.
    public internal(set) var choice: AIProviderChoice {
        didSet {
            guard choice != oldValue else { return }
            openRouterSetAside = false
            defaults.set(choice.rawValue, forKey: Self.choiceKey)
            selection += 1
            for cancel in pending.values { cancel() }
            pending = [:]
            for confirmation in confirmations.values { confirmation.resume(returning: .stop) }
            confirmations = [:]
            firstSendInFlight = false
            states = states.filter { _, state in
                switch state {
                case .working, .confirming: false
                default: true
                }
            }
            availabilityStatus = nil
        }
    }
    /// The OpenRouter key and model, for Settings; `nil` where OpenRouter is not offered.
    public let openRouter: OpenRouterAccount?
    /// Whether a request the user confirmed in the send preview went out this session, so it is not shown again.
    public private(set) var sendConfirmed = false
    /// Sends folder names deeper than the first level under `~` instead of placeholders. Off by default.
    public var sendFolderNames: Bool {
        didSet {
            let sending = sendFolderNames
            sendingFolderNames.withLock { $0 = sending }
            defaults.set(sendFolderNames, forKey: Self.sendFolderNamesKey)
        }
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
    /// Whether the stored choice of OpenRouter started as None only because whether a key is stored could not be read
    /// at launch, so it comes back once a later read finds the key; anything else the user does with the provider or
    /// the key ends that.
    @ObservationIgnored private var openRouterSetAside = false
    /// Whether the request the user confirmed in the send preview has not ended yet, so every other one waits for it.
    @ObservationIgnored private var firstSendInFlight = false
    /// Each item waiting for the send preview's answer, or for the confirmed request to end.
    @ObservationIgnored private var confirmations: [StateKey: CheckedContinuation<Resumption, Never>] = [:]
    /// Exactly what was sent for each item, for What was sent.
    @ObservationIgnored private var sentTexts: [StateKey: String] = [:]
    /// `sendFolderNames`, read where a request is handed to the network, off the main actor, right before each attempt.
    @ObservationIgnored private let sendingFolderNames = OSAllocatedUnfairLock(initialState: false)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeProvider: @MainActor (AIProviderChoice) -> (any AIProvider)?
    @ObservationIgnored private let baseRedactor: ExplainRedactor
    @ObservationIgnored private let availabilityTimeout: Duration
    @ObservationIgnored private let answerTimeout: Duration

    static let choiceKey = "explainProvider"
    static let sendFolderNamesKey = "explainSendFolderNames"

    private struct StateKey: Hashable, Sendable {
        let choice: AIProviderChoice
        let item: ExplainKey
    }

    /// Why an item waiting for the send preview, or for the confirmed request, goes on.
    private enum Resumption: Sendable {
        /// The user sent what the preview showed.
        case confirmed
        /// The confirmed request ended: sent now if it went out, otherwise previewed.
        case released
        /// Cancelled by the user or the caller, or the provider changed: nothing is sent.
        case stop
    }

    /// `availabilityTimeout` and `answerTimeout` bound how long the provider may take to say whether it is available
    /// and to answer. `provider` makes the chosen provider; by default, the live one (`liveProvider(_:openRouter:)`).
    /// A stored choice of OpenRouter with no key stored starts as None, and is stored as None; one whose key could not
    /// be read starts as None until a later read finds it (`refreshAvailability()`).
    public init(defaults: UserDefaults = .standard, redactor: ExplainRedactor, openRouter: OpenRouterAccount? = nil,
                provider: (@MainActor (AIProviderChoice) -> (any AIProvider)?)? = nil,
                availabilityTimeout: Duration = .seconds(15), answerTimeout: Duration = .seconds(90)) {
        self.defaults = defaults
        baseRedactor = redactor
        self.openRouter = openRouter
        makeProvider = provider ?? { choice in Self.liveProvider(choice, openRouter: openRouter) }
        self.availabilityTimeout = availabilityTimeout
        self.answerTimeout = answerTimeout
        let stored = defaults.string(forKey: Self.choiceKey).flatMap(AIProviderChoice.init(rawValue:)) ?? .none
        let setAside = stored == .openRouter && openRouter?.hasKey != true
        choice = setAside ? .none : stored
        openRouterSetAside = setAside && openRouter?.presenceFailed == true
        if setAside, !openRouterSetAside { defaults.set(AIProviderChoice.none.rawValue, forKey: Self.choiceKey) }
        sendFolderNames = defaults.bool(forKey: Self.sendFolderNamesKey)
        let sending = sendFolderNames
        sendingFolderNames.withLock { $0 = sending }
        openRouter?.onKeyRemoved = { [weak self] in
            if self?.choice == .openRouter { self?.choice = .none }
        }
        openRouter?.onKeyChange = { [weak self] in self?.openRouterSetAside = false }
    }

    /// This Mac's account, with placeholders keyed for this session, and the OpenRouter key in this Mac's Keychain.
    public static func live() -> ExplainCenter {
        ExplainCenter(redactor: .live(sendFolderNames: false, key: ExplainRedactor.sessionKey()),
                      openRouter: OpenRouterAccount(keys: OpenRouterKeyStore(), client: OpenRouterClient()))
    }

    public static func liveProvider(_ choice: AIProviderChoice, openRouter: OpenRouterAccount?) -> (any AIProvider)? {
        switch choice {
        case .none: nil
        case .appleIntelligence: AppleIntelligenceProvider()
        case .openRouter: openRouter?.provider()
        }
    }

    /// Whether `choice` can be picked now: OpenRouter only while a key is stored.
    public func canChoose(_ choice: AIProviderChoice) -> Bool {
        choice != .openRouter || openRouter?.hasKey == true
    }

    /// Picks the provider, when it can be picked now (`canChoose(_:)`); returns whether it is the provider then.
    @discardableResult
    public func choose(_ choice: AIProviderChoice) -> Bool {
        guard canChoose(choice) else { return false }
        self.choice = choice
        return true
    }

    /// Redacts with the current **Send folder names** setting.
    public var redactor: ExplainRedactor { baseRedactor.sendingFolderNames(sendFolderNames) }

    public func state(for item: ExplainKey) -> ExplainState {
        guard choice != .none else { return .needsProvider }
        return states[StateKey(choice: choice, item: item)] ?? .idle
    }

    /// Exactly what was sent for the item with the chosen provider, once it was sent.
    public func sentText(for item: ExplainKey) -> String? {
        sentTexts[StateKey(choice: choice, item: item)]
    }

    /// Sends the item shown in the send preview first, then every other item waiting for one; once it has gone out, no
    /// preview is shown again this session.
    public func confirmSend(_ item: ExplainKey) {
        resolveConfirmation(StateKey(choice: choice, item: item), .confirmed)
    }

    /// Sends nothing for the item shown in the send preview; it can be asked again.
    public func cancelSend(_ item: ExplainKey) {
        resolveConfirmation(StateKey(choice: choice, item: item), .stop)
    }

    /// Reads the chosen provider's availability, for Settings, each time it is shown, when the provider changes, and
    /// when the user checks again. A read that a later one overtakes is not shown. Whether an OpenRouter key is stored
    /// is read again first; a stored choice of OpenRouter that started as None only because that read failed at launch
    /// comes back once it finds the key, and is stored as None once it finds none.
    public func refreshAvailability() async {
        if let openRouter {
            await openRouter.refreshKey()
            if openRouterSetAside, !openRouter.presenceFailed {
                if openRouter.hasKey {
                    choice = .openRouter
                } else {
                    openRouterSetAside = false
                    defaults.set(AIProviderChoice.none.rawValue, forKey: Self.choiceKey)
                }
            }
        }
        guard choice != .none, let provider = makeProvider(choice) else { return }
        _ = try? await readAvailability(of: provider, in: selection)
    }

    /// `provider`'s availability, or `nil` when it does not answer in time; throws `CancellationError` when its caller
    /// is cancelled or the provider changes, which is not a timeout. Settings shows it as checking while it is read,
    /// then what it answered or that it did not answer in time, only while no later read has started and the provider
    /// has not changed since `selection`, so a slow read never replaces a newer one.
    private func readAvailability(of provider: any AIProvider, in selection: Int) async throws -> AIAvailability? {
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
            throw CancellationError()
        }
        if selection == self.selection, read == availabilityReads {
            availabilityStatus = availability.map(AvailabilityStatus.read) ?? .noAnswer(seconds: availabilityTimeout.components.seconds)
        }
        return availability
    }

    /// Explains an item with the chosen provider, building its request with the current redactor. Does nothing without
    /// a provider, while the item is being explained, or once it has been. Returns when the answer is in. When the
    /// user changes the provider meanwhile, even back to this one, the work is cancelled, the request is not sent if it
    /// has not been yet, no answer is kept, and the item can be explained again at once. When the user changes **Send
    /// folder names** before the request goes out, even while its key is read, it is not sent: it is built again with
    /// the setting as it is then, and previewed again while the session's preview is still required; when they change
    /// it before the retry of a request that went out, the retry is not sent and the item fails. When
    /// the provider does not say in time whether it is available, or does not answer in time, the item fails and can be
    /// asked again. When the caller is cancelled, nothing more is sent, no failure is kept, and the item can be asked
    /// again.
    public func explain(_ item: ExplainKey, request build: (ExplainRedactor) -> ExplainRequest?) async {
        let choice = self.choice
        let selection = self.selection
        let key = StateKey(choice: choice, item: item)
        switch states[key] {
        case .working?, .confirming?, .explained?: return
        default: break
        }
        guard choice != .none, let provider = makeProvider(choice) else { return }
        let sendFolderNames = self.sendFolderNames
        guard var request = build(redactor) else {
            states[key] = .gone
            return
        }
        states[key] = .working(request)
        let read: AIAvailability?
        do {
            read = try await readAvailability(of: provider, in: selection)
        } catch {
            // Cancelled by the caller or a provider change, which is not the provider failing to answer: no failure is
            // kept. After a provider change the item's state is no longer this call's.
            if selection == self.selection { states[key] = nil }
            return
        }
        // The provider changed meanwhile: this item's state is no longer this call's (a new request may have begun).
        guard selection == self.selection else { return }
        // Cancelled as the read answered: nothing is sent.
        guard !Task.isCancelled else {
            states[key] = nil
            return
        }
        guard let availability = read else {
            states[key] = .failed(Self.late(choice, availabilityTimeout) + " Nothing was sent.", request)
            return
        }
        guard availability.isAvailable else {
            states[key] = .unavailable(availability)
            return
        }
        var builtWith = sendFolderNames
        while true {
            var isFirstSend = false
            while true {
                // Built with the setting the user has now, so a folder name is never sent once they turn it off.
                if builtWith != self.sendFolderNames {
                    guard let rebuilt = build(redactor) else {
                        states[key] = .gone
                        return
                    }
                    request = rebuilt
                    builtWith = self.sendFolderNames
                    states[key] = .working(request)
                }
                guard provider.needsSendPreview else { break }
                if firstSendInFlight {
                    // The request the user confirmed has not ended yet: this one waits, so that one is sent first, then
                    // is sent, or previewed if that one did not go out.
                    states[key] = .working(request)
                    let resumption = await confirmation(for: key)
                    guard selection == self.selection else { return }
                    guard resumption != .stop, !Task.isCancelled else {
                        states[key] = nil
                        return
                    }
                    continue
                }
                if sendConfirmed { break }
                let text: String
                do {
                    text = try provider.sentText(for: request)
                } catch {
                    states[key] = .failed("The request could not be prepared. Nothing was sent.", request)
                    return
                }
                states[key] = .confirming(SendPreview(provider: choice, text: text, request: request))
                let resumption = await confirmation(for: key)
                // The provider changed meanwhile: this item's state is no longer this call's.
                guard selection == self.selection else { return }
                guard resumption != .stop, !Task.isCancelled else {
                    states[key] = nil
                    return
                }
                states[key] = .working(request)
                // Released once another item's confirmed request ended, or confirmed while another one is on its way:
                // sent once that one went out, otherwise previewed again.
                guard resumption == .confirmed, !firstSendInFlight, !sendConfirmed else { continue }
                // What was shown is sent only if Send folder names is as it was; otherwise it is built again and shown.
                guard builtWith != self.sendFolderNames else {
                    firstSendInFlight = true
                    isFirstSend = true
                    // Every other item waiting for a preview waits until this request has ended, without its preview:
                    // it is then sent, built with the setting as it is then, if this one went out, and previewed
                    // otherwise.
                    for (other, state) in states where other != key && other.choice == choice {
                        if case let .confirming(preview) = state { states[other] = .working(preview.request) }
                    }
                    break
                }
            }
            // Each attempt, the retry included, goes out only while Send folder names is as it was when the request was
            // built; whether one went out is noted then.
            let submitted = OSAllocatedUnfairLock(initialState: false)
            let current = sendingFolderNames
            let folderNames = builtWith
            let submitting: @Sendable () -> Bool = {
                guard current.withLock({ $0 }) == folderNames else { return false }
                submitted.withLock { $0 = true }
                return true
            }
            let outcome: ExplainState?
            var outdated = false
            do {
                defer {
                    if isFirstSend {
                        // Only a confirmed body that went out ends the preview for the session; one that did not (no
                        // key read, cancelled, timed out, Send folder names changed, or the provider changed first)
                        // leaves it required.
                        if submitted.withLock({ $0 }) { sendConfirmed = true }
                        // The first request ended: the others waiting for it go on now. After a provider change they
                        // were already ended, and the requests waiting then are not this one's.
                        if selection == self.selection {
                            firstSendInFlight = false
                            resolveAllConfirmations(.released)
                        }
                    }
                }
                do {
                    sentTexts[key] = try provider.sentText(for: request)
                } catch {
                    states[key] = .failed("The request could not be prepared. Nothing was sent.", request)
                    return
                }
                do {
                    let sent = request
                    let timeout = answerTimeout
                    let draft = try await untilProviderChanges {
                        try await answer(within: timeout, { try await provider.explain(sent, submitting: submitting) })
                    }
                    if let draft {
                        outcome = .explained(try Explanation(validating: draft, for: request), request)
                    } else {
                        outcome = .failed(Self.late(choice, answerTimeout), request)
                    }
                } catch ExplainError.outdated {
                    outcome = nil
                    outdated = true
                } catch let ExplainError.unavailable(availability) {
                    outcome = .unavailable(availability)
                } catch let error as ExplainError {
                    outcome = .failed(error.message, request)
                } catch is CancellationError {
                    outcome = nil
                } catch {
                    outcome = .failed(error.localizedDescription, request)
                }
            }
            guard selection == self.selection else { return }
            guard outdated, !Task.isCancelled else {
                states[key] = outcome
                return
            }
            guard !submitted.withLock({ $0 }) else {
                // The request went out, and its retry was not sent.
                states[key] = .failed("Send folder names changed before \(choice.title) was asked again, so it was not "
                    + "asked again. Ask again.", request)
                return
            }
            // Nothing went out: built again with the setting as it is now, and previewed again while required.
            sentTexts[key] = nil
            states[key] = .working(request)
        }
    }

    /// Whether the user confirms the send preview shown for `key`, or the confirmed request `key` waits for ended:
    /// `.stop` when they cancel, the provider changes, or the caller is cancelled.
    private func confirmation(for key: StateKey) async -> Resumption {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .stop) }
                confirmations[key] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resolveConfirmation(key, .stop) }
        }
    }

    private func resolveConfirmation(_ key: StateKey, _ resumption: Resumption) {
        confirmations.removeValue(forKey: key)?.resume(returning: resumption)
    }

    private func resolveAllConfirmations(_ resumption: Resumption) {
        let waiting = confirmations
        confirmations = [:]
        for confirmation in waiting.values { confirmation.resume(returning: resumption) }
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
