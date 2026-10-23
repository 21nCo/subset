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
    /// Waiting for the user to confirm the send preview, shown for each request off this Mac until one the user
    /// confirmed this session has been answered; nothing has been sent.
    case confirming(SendPreview)
    case explained(Explanation, ExplainRequest)
    /// The provider cannot answer now; nothing was sent.
    case unavailable(AIAvailability)
    case failed(String, ExplainRequest)
    /// The item left the sample or scan before its request was built; nothing was sent.
    case gone
}

/// What the send preview shows: exactly the body the provider sends for the request, byte for byte.
public struct SendPreview: Equatable, Sendable {
    public let provider: AIProviderChoice
    public let request: ExplainRequest
    public let body: Data

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// The Explain setting and each item's explanation. Nothing is sent until the user picks a provider (`choice` starts
/// as `.none`, and with `.none` no provider is made or called). Explanations are kept in memory for the session, per
/// provider and item; a failed or unavailable one can be asked again. A provider that does not answer in time is
/// given up on, so an item is never left being explained. Changing the provider ends the work begun with the one
/// before: it is cancelled, nothing it had not sent yet is sent, and nothing it answers is kept, even when the user
/// picks that provider again before it finishes.
///
/// OpenRouter (SET-160) can be chosen only while its key is stored. A check that finds it cannot be used (the key
/// removed or not found, the Keychain not answering, or a model ID entry that held the key or could not be compared
/// with it) sets the choice back to the on-device provider and says why (`notice`), so the choice never stays on a
/// provider that cannot run, and what is stored is always what is shown. Until OpenRouter has answered a request whose
/// body the user confirmed in the send preview this session, every request to it waits in `.confirming` for its own
/// preview, and cancelling it sends nothing; the body sent is the one shown. Add Key and Remove Key end the OpenRouter
/// work in flight as they start, and until they finish no request to OpenRouter is begun or sent
/// (`keyChanging`), so nothing is sent with the key being replaced or removed. Changing **Send folder names** ends the
/// previews and sends off this Mac built with the setting before, so nothing built with it goes out, a retry included.
@MainActor
@Observable
public final class ExplainCenter {
    /// Changed by `choose(_:)`, and set back from OpenRouter by a check that finds it cannot be used.
    public private(set) var choice: AIProviderChoice {
        didSet {
            guard choice != oldValue else { return }
            defaults.set(choice.rawValue, forKey: Self.choiceKey)
            endWork()
        }
    }
    /// Why the choice was set back from OpenRouter; cleared when the user next chooses a provider.
    public private(set) var notice: String?
    /// Whether OpenRouter answered a request whose body the user confirmed in the send preview this session, so the
    /// preview is not shown again: with an explanation, or with an error or refusal (`ExplainError.rejected`), which
    /// shows the request reached it. A confirmed request that is cancelled, refused before it is sent, or not answered
    /// (no connection, or no answer in time, when whether it reached OpenRouter is not known) leaves the preview
    /// required.
    public private(set) var sendConfirmed = false
    /// Sends folder names deeper than the first level under `~` instead of placeholders. Off by default.
    public var sendFolderNames: Bool {
        didSet {
            guard sendFolderNames != oldValue else { return }
            defaults.set(sendFolderNames, forKey: Self.sendFolderNamesKey)
            folderNamesChanges += 1
            // Built with the setting before: a preview is not sent, and a send off this Mac sends nothing more.
            for (key, _) in previews {
                if case let .confirming(preview) = states[key] { states[key] = .failed(Self.changedBeforeSending, preview.request) }
            }
            previews = [:]
            for work in pending.values where work.sendsOffThisMac { work.cancel() }
        }
    }
    /// The chosen provider's availability from its latest read, which may still be checking or may not have answered
    /// in time; `nil` before any read and for `.none`.
    public private(set) var availabilityStatus: AvailabilityStatus?
    /// The chosen provider's availability when the latest read answered.
    public var availability: AIAvailability? { availabilityStatus?.availability }
    private var states: [StateKey: ExplainState] = [:]
    /// Exactly what was sent off this Mac for each item explained, for What was sent.
    private var sentBodies: [StateKey: Data] = [:]
    /// Counts availability reads, so only the latest one is shown.
    @ObservationIgnored private var availabilityReads = 0
    /// Counts provider changes, and Add Key and Remove Key while OpenRouter is chosen, so work begun before the latest
    /// one changes nothing.
    @ObservationIgnored private var selection = 0
    /// Counts changes of **Send folder names**, so a send it stopped says so.
    @ObservationIgnored private var folderNamesChanges = 0
    /// Each availability read and answer in flight, by when it began.
    @ObservationIgnored private var pending: [Int: Pending] = [:]
    @ObservationIgnored private var pendingCount = 0
    /// The provider each item in `.confirming` is sent with once confirmed, so the body sent is the one shown.
    @ObservationIgnored private var previews: [StateKey: any AIProvider] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let openRouter: OpenRouterAccount?
    @ObservationIgnored private let makeProvider: @MainActor (AIProviderChoice) -> (any AIProvider)?
    @ObservationIgnored private let baseRedactor: ExplainRedactor
    @ObservationIgnored private let availabilityTimeout: Duration
    @ObservationIgnored private let answerTimeout: Duration

    static let choiceKey = "explainProvider"
    static let sendFolderNamesKey = "explainSendFolderNames"
    static let changedBeforeSending = "Send folder names changed, so this request was not sent. Try again to review it "
        + "with the setting as it is now."
    static let changedWhileSending = "Send folder names changed while this request was being sent, so nothing more was "
        + "sent. Try again."
    static let keyChanging = "The OpenRouter key is being changed, so nothing was sent. Try again once Settings shows "
        + "it."

    private struct StateKey: Hashable {
        let choice: AIProviderChoice
        let item: ExplainKey
    }

    private struct Pending {
        let cancel: @Sendable () -> Void
        /// Whether it sends a request off this Mac, which a change of **Send folder names** stops.
        let sendsOffThisMac: Bool
    }

    /// `availabilityTimeout` and `answerTimeout` bound how long the provider may take to say whether it is available
    /// and to answer. `provider` makes the chosen provider; by default, the live one (`liveProvider(_:openRouter:)`).
    /// OpenRouter is offered only with `openRouter`; a stored choice of it is kept until a check says otherwise, unless
    /// no key is known to be stored.
    public init(defaults: UserDefaults = .standard, redactor: ExplainRedactor, openRouter: OpenRouterAccount? = nil,
                provider: (@MainActor (AIProviderChoice) -> (any AIProvider)?)? = nil,
                availabilityTimeout: Duration = .seconds(15), answerTimeout: Duration = .seconds(90)) {
        self.defaults = defaults
        baseRedactor = redactor
        self.openRouter = openRouter
        makeProvider = provider ?? { Self.liveProvider($0, openRouter: openRouter) }
        self.availabilityTimeout = availabilityTimeout
        self.answerTimeout = answerTimeout
        let stored = defaults.string(forKey: Self.choiceKey).flatMap(AIProviderChoice.init(rawValue:)) ?? .none
        if stored == .openRouter, openRouter.map({ $0.presence == .absent }) ?? true {
            choice = .appleIntelligence
            defaults.set(AIProviderChoice.appleIntelligence.rawValue, forKey: Self.choiceKey)
            notice = Self.notice(.noKey)
        } else {
            choice = stored
        }
        sendFolderNames = defaults.bool(forKey: Self.sendFolderNamesKey)
        openRouter?.onSetback = { [weak self] setback in self?.setBack(setback) }
        openRouter?.onKeyChange = { [weak self] in
            if self?.choice == .openRouter { self?.endWork() }
        }
        // The change ended the status Settings showed; it is read again while OpenRouter is still chosen.
        openRouter?.onKeyChangeEnd = { [weak self] in
            guard let self, choice == .openRouter else { return }
            Task { await self.refreshAvailability() }
        }
    }

    /// This Mac's account, with placeholders keyed for this session, and OpenRouter with `openRouter`'s key and model.
    public static func live(openRouter: OpenRouterAccount) -> ExplainCenter {
        ExplainCenter(redactor: .live(sendFolderNames: false, key: ExplainRedactor.sessionKey()), openRouter: openRouter)
    }

    public static func liveProvider(_ choice: AIProviderChoice, openRouter: OpenRouterAccount?) -> (any AIProvider)? {
        switch choice {
        case .none: nil
        case .appleIntelligence: AppleIntelligenceProvider()
        case .openRouter: openRouter?.provider()
        }
    }

    /// Whether `choice` can be picked now: OpenRouter only while its key is known to be stored and is not being
    /// changed.
    public func canChoose(_ choice: AIProviderChoice) -> Bool {
        guard choice == .openRouter else { return true }
        guard let openRouter else { return false }
        return openRouter.presence == .stored && !openRouter.isChangingKey
    }

    /// Why OpenRouter cannot be picked now, for Settings to say beside the provider; `nil` when it can.
    public var openRouterUnavailableReason: String? {
        guard !canChoose(.openRouter) else { return nil }
        guard let openRouter else { return Self.waitsForKey }
        if openRouter.isChangingKey { return Self.waitsForKeyChange }
        return openRouter.presence == .absent ? Self.waitsForKey : Self.waitsForKeychain
    }

    static let waitsForKey = "OpenRouter can be chosen once its API key is stored below."
    static let waitsForKeyChange = "OpenRouter can be chosen once the key change below is finished."
    static let waitsForKeychain = "OpenRouter can be chosen once the Keychain says whether its API key is stored. "
        + "Settings asks again each time it is opened."

    /// Picks the provider when it can be picked now (`canChoose(_:)`), and returns whether it was.
    @discardableResult
    public func choose(_ choice: AIProviderChoice) -> Bool {
        guard canChoose(choice) else { return false }
        notice = nil
        self.choice = choice
        return true
    }

    /// Redacts with the current **Send folder names** setting.
    public var redactor: ExplainRedactor { baseRedactor.sendingFolderNames(sendFolderNames) }

    public func state(for item: ExplainKey) -> ExplainState {
        guard choice != .none else { return .needsProvider }
        return states[StateKey(choice: choice, item: item)] ?? .idle
    }

    /// Exactly what was sent off this Mac for the item explained with the chosen provider; `nil` when nothing left
    /// this Mac.
    public func sentText(for item: ExplainKey) -> String? {
        sentBodies[StateKey(choice: choice, item: item)].map { String(decoding: $0, as: UTF8.self) }
    }

    /// Ends the work in flight: it is cancelled, nothing it had not sent is sent, nothing it answers is kept, and its
    /// items, and those waiting for the send preview, can be asked again.
    private func endWork() {
        selection += 1
        for work in pending.values { work.cancel() }
        pending = [:]
        previews = [:]
        states = states.filter { _, state in
            switch state {
            case .working, .confirming: false
            default: true
            }
        }
        availabilityStatus = nil
    }

    /// Sets the choice back from OpenRouter to the on-device provider, saying why, when a check finds it cannot be used.
    private func setBack(_ setback: OpenRouterAccount.Setback) {
        guard choice == .openRouter else { return }
        choice = .appleIntelligence
        notice = Self.notice(setback)
    }

    static func notice(_ setback: OpenRouterAccount.Setback) -> String {
        switch setback {
        case .noKey: "No OpenRouter key is stored, so Explain uses Apple Intelligence, on this Mac, instead. Add a key in "
            + "Settings to choose OpenRouter again."
        case .keyUnreadable: "The Keychain did not say whether an OpenRouter key is stored, so Explain uses Apple "
            + "Intelligence, on this Mac, instead. Choose OpenRouter again once Settings shows the key."
        case .modelHeldKey: "The OpenRouter model ID held your API key, so it was cleared and Explain uses Apple "
            + "Intelligence, on this Mac, instead. Choose OpenRouter again to use another model ID or openrouter/auto."
        case .modelUnchecked: "The Keychain did not return the OpenRouter key to check the model ID with, so Explain uses "
            + "Apple Intelligence, on this Mac, instead. Choose OpenRouter again once Settings shows the key."
        }
    }

    /// Sets the choice back from OpenRouter when what `provider` answered means it cannot be used. When no key is
    /// found, or it cannot be read, whether one is stored is read again, so Settings shows it as it is; a model ID that
    /// held the key is cleared (`OpenRouterAccount.refuseModel(sent:)`).
    private func noteOpenRouter(_ availability: AIAvailability, from provider: any AIProvider) {
        switch availability {
        case .noOpenRouterKey, .openRouterKeyUnreadable:
            setBack(availability == .noOpenRouterKey ? .noKey : .keyUnreadable)
            if let openRouter { Task { await openRouter.refreshKey() } }
        case .openRouterModelHeldKey:
            setBack(.modelHeldKey)
            if let sent = (provider as? OpenRouterProvider)?.model { openRouter?.refuseModel(sent: sent) }
        default: break
        }
    }

    /// Whether `choice` is OpenRouter while Add Key or Remove Key waits for the Keychain: no request to it is begun or
    /// sent then, since what it would read is the key being replaced or removed.
    private func keyChanging(_ choice: AIProviderChoice) -> Bool {
        choice == .openRouter && openRouter?.isChangingKey == true
    }

    /// Reads the chosen provider's availability, for Settings, each time it is shown, when the provider changes, and
    /// when the user checks again. A read that a later one overtakes is not shown.
    public func refreshAvailability() async {
        guard choice != .none, let provider = makeProvider(choice) else { return }
        _ = try? await readAvailability(of: provider, in: selection)
    }

    /// `provider`'s availability, or `nil` when it does not answer in time; throws `CancellationError` when its caller
    /// is cancelled or the provider changes, which is not a timeout. Settings shows it as checking while it is read,
    /// then what it answered or that it did not answer in time, only while no later read has started and the provider
    /// has not changed since `selection`, so a slow read never replaces a newer one. OpenRouter's answer that no key is
    /// stored, that it cannot be read, or that the model ID holds it sets the choice back. `beforeSending` reads it as
    /// a request is about to be built (`OpenRouterProvider.availabilityBeforeSending()`), so a model ID holding the key
    /// sets the choice back before anything is previewed.
    private func readAvailability(of provider: any AIProvider, in selection: Int,
                                  beforeSending: Bool = false) async throws -> AIAvailability? {
        availabilityReads += 1
        let read = availabilityReads
        availabilityStatus = .checking
        let availability: AIAvailability?
        do {
            let timeout = availabilityTimeout
            availability = try await untilProviderChanges {
                try await answer(within: timeout, {
                    if beforeSending, let openRouter = provider as? OpenRouterProvider {
                        await openRouter.availabilityBeforeSending()
                    } else {
                        await provider.availability()
                    }
                })
            }
        } catch {
            // Cancelled, as when Settings closes: not a status; the next read shows one.
            if selection == self.selection, read == availabilityReads { availabilityStatus = nil }
            throw CancellationError()
        }
        if selection == self.selection, read == availabilityReads {
            availabilityStatus = availability.map(AvailabilityStatus.read) ?? .noAnswer(seconds: availabilityTimeout.components.seconds)
        }
        if selection == self.selection, let availability { noteOpenRouter(availability, from: provider) }
        return availability
    }

    /// Explains an item with the chosen provider, building its request with the current redactor. Does nothing without
    /// a provider, while the item is being explained or waits for the send preview, or once it has been explained.
    /// Returns when the answer is in, or when the item waits for the send preview (`confirmSend(_:)`). When the
    /// user changes the provider meanwhile, even back to this one, the work is cancelled, the request is not sent if it
    /// has not been yet, no answer is kept, and the item can be explained again at once; when
    /// the user changes **Send folder names** before it is sent, it is built again with the setting as it is then. When
    /// the provider does not say in time whether it is available, or does not answer in time, the item fails and can be
    /// asked again. When the caller is cancelled, nothing more is sent, no failure is kept, and the item can be asked
    /// again. While the OpenRouter key is being changed, an OpenRouter request fails at once and nothing is sent.
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
        guard !keyChanging(choice) else {
            states[key] = .failed(Self.keyChanging, request)
            return
        }
        states[key] = .working(request)
        let read: AIAvailability?
        do {
            read = try await readAvailability(of: provider, in: selection, beforeSending: true)
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
        // Built with the setting the user has now, so a folder name is never sent once they turn it off.
        if sendFolderNames != self.sendFolderNames {
            guard let rebuilt = build(redactor) else {
                states[key] = .gone
                return
            }
            request = rebuilt
            states[key] = .working(request)
        }
        let body: Data?
        do {
            body = try provider.sentBody(for: request)
        } catch {
            states[key] = .failed("The request could not be prepared. Nothing was sent.", request)
            return
        }
        // Off this Mac, until a body the user confirmed has been answered this session: shown first.
        if let body, !sendConfirmed {
            previews[key] = provider
            states[key] = .confirming(SendPreview(provider: choice, request: request, body: body))
            return
        }
        await send(request, body: body, with: provider, for: key, in: selection, confirmed: false)
    }

    /// Sends exactly the body the send preview showed for the item, with the provider it was built for, and returns
    /// when the answer is in. Once OpenRouter has answered it, no preview is shown again this session.
    public func confirmSend(_ item: ExplainKey) async {
        let key = StateKey(choice: choice, item: item)
        guard case let .confirming(preview) = states[key], let provider = previews.removeValue(forKey: key) else { return }
        states[key] = .working(preview.request)
        await send(preview.request, body: preview.body, with: provider, for: key, in: selection, confirmed: true)
    }

    /// Sends nothing for the item waiting for the send preview; it can be asked again.
    public func cancelSend(_ item: ExplainKey) {
        let key = StateKey(choice: choice, item: item)
        guard case .confirming = states[key] else { return }
        previews[key] = nil
        states[key] = nil
    }

    /// Asks `provider` to explain `request`, whose body sent off this Mac, if any, is `body`, and keeps the outcome
    /// unless the provider changed since `selection`. `confirmed` is whether the user confirmed `body` in the preview.
    /// Sends nothing while the OpenRouter key is being changed.
    private func send(_ request: ExplainRequest, body: Data?, with provider: any AIProvider, for key: StateKey,
                      in selection: Int, confirmed: Bool) async {
        guard !keyChanging(key.choice) else {
            if selection == self.selection { states[key] = .failed(Self.keyChanging, request) }
            return
        }
        let folderNamesChanges = self.folderNamesChanges
        var answered = false
        let outcome: ExplainState?
        do {
            let timeout = answerTimeout
            let draft = try await untilProviderChanges(sendsOffThisMac: body != nil) {
                try await answer(within: timeout, { try await provider.explain(request) })
            }
            if let draft {
                answered = true
                outcome = .explained(try Explanation(validating: draft, for: request), request)
            } else {
                outcome = .failed(Self.late(key.choice, answerTimeout), request)
            }
        } catch let ExplainError.unavailable(availability) {
            outcome = .unavailable(availability)
        } catch let error as ExplainError {
            // Rejected answers came from the provider, so the request reached it.
            switch error {
            case .invalidResponse, .rejected: answered = true
            default: break
            }
            outcome = .failed(error.message, request)
        } catch is CancellationError {
            outcome = folderNamesChanges == self.folderNamesChanges ? nil : .failed(Self.changedWhileSending, request)
        } catch {
            outcome = .failed(error.localizedDescription, request)
        }
        if confirmed, answered { sendConfirmed = true }
        guard selection == self.selection else { return }
        if case let .unavailable(availability)? = outcome {
            // Refused before it was sent: nothing left this Mac. A refusal that sets the choice back ends this work,
            // so it is not kept as the item's state when OpenRouter is chosen again.
            noteOpenRouter(availability, from: provider)
            guard selection == self.selection else { return }
            states[key] = outcome
            sentBodies[key] = nil
            return
        }
        states[key] = outcome
        sentBodies[key] = outcome == nil ? nil : body
    }

    /// `operation`'s result, run so that changing the provider cancels it, as cancelling the caller does, and so does
    /// changing **Send folder names** when it sends off this Mac.
    private func untilProviderChanges<T: Sendable>(
        sendsOffThisMac: Bool = false, _ operation: @escaping @Sendable () async throws -> T?
    ) async throws -> T? {
        let task = Task { try await operation() }
        pendingCount += 1
        let id = pendingCount
        pending[id] = Pending(cancel: { task.cancel() }, sendsOffThisMac: sendsOffThisMac)
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
