import Foundation
import Observation

/// The OpenRouter part of Settings: **Add key**, **Test key**, **Remove key**, and the model ID. Only whether a key is
/// stored is kept here; the key itself stays in the Keychain (`OpenRouterKeyStore`) and is read, off the main actor, only
/// to send a request or the key test and, unless no key is known to be stored (`presence`), to check that a model ID
/// entered does not contain it. No Keychain call is made on the main actor: whether a key is stored is read when the
/// app asks (`refreshKey()`, at launch and each time Settings is shown), and Add key and Remove key wait for theirs.
/// The model ID is kept in user defaults; the key never is. Explain uses OpenRouter through `provider()` once the user
/// chooses it (SET-160); each check here that leaves it unusable is reported (`onSetback`), so the choice goes back to
/// the on-device provider.
@MainActor
@Observable
public final class OpenRouterAccount {
    /// Where the latest key test stands.
    public enum KeyTest: Equatable, Sendable {
        case testing
        case passed
        case failed(String)
    }

    /// Whether a key is stored, as last read or changed here.
    public enum KeyPresence: Equatable, Sendable {
        case stored
        case absent
        /// Not read yet, or the latest read of it failed; `shown` is whether Settings shows a key stored meanwhile.
        case unknown(shown: Bool)
    }

    /// A check that found OpenRouter cannot be used as it is: no key is stored, the Keychain did not answer whether one
    /// is, or the model ID entered held the key or could not be compared with it.
    public enum Setback: Equatable, Sendable {
        case noKey
        case keyUnreadable
        case modelHeldKey
        case modelUnchecked
    }

    /// Set by every read of whether a key is stored, and by Add key, Remove key and the key test. A model ID entry is
    /// kept without comparing it with the key only while this is `absent`. Once it is known again, an entry that could
    /// not be checked is checked again, so what is used, and what Settings says about it, follow it. Each time it is
    /// set to anything but `stored`, that is reported (`onSetback`).
    public private(set) var presence: KeyPresence {
        didSet {
            if modelUnchecked, modelCheck == nil, presence == .stored || presence == .absent { keep(model) }
            switch presence {
            case .stored: break
            case .absent: onSetback?(.noKey)
            case .unknown: onSetback?(.keyUnreadable)
            }
        }
    }
    /// Told each time a check finds OpenRouter cannot be used as it is: whether a key is stored is set to anything but
    /// stored, or a model ID entered is cleared because it held the key or is not used because it could not be compared
    /// with it. `ExplainCenter` sets it.
    @ObservationIgnored public var onSetback: (@MainActor (Setback) -> Void)?
    /// Told when Add key or Remove key starts, before the Keychain is changed, so `ExplainCenter` ends the OpenRouter
    /// work in flight and nothing more is sent with the key being replaced or removed.
    @ObservationIgnored public var onKeyChange: (@MainActor () -> Void)?
    /// Told when the last Add key or Remove key in flight has finished, once Settings shows what it found, so
    /// `ExplainCenter` reads OpenRouter's availability again for Settings.
    @ObservationIgnored public var onKeyChangeEnd: (@MainActor () -> Void)?
    /// Whether an Add key or Remove key is waiting for the Keychain; Settings does not offer Test key meanwhile.
    public var isChangingKey: Bool { pendingKeyChanges > 0 }
    /// Whether Settings shows a key stored: Test key and Remove key are offered then.
    public var hasKey: Bool {
        switch presence {
        case .stored: true
        case .absent: false
        case let .unknown(shown): shown
        }
    }
    /// Why the latest Add key, Remove key, or Keychain read failed; cleared by the next one that works.
    public private(set) var keyError: String?
    public private(set) var keyTest: KeyTest?
    /// The Model field's text while it is edited. Nothing in it is checked, kept or used until it is committed
    /// (`commitModel()`, on Return or when the field loses focus), so a partial entry changes neither the model ID used
    /// nor what Settings says about it. An entry with `sk-or-` in it is cleared at once, as `model` clears it.
    public var modelEntry: String {
        didSet {
            if OpenRouterProvider.looksLikeKey(modelEntry) { model = modelEntry }
        }
    }
    /// The model ID as the user entered and committed it. An entry with an API key anywhere in it (`sk-or-`, or the
    /// key stored, whichever was entered first) is refused: it is cleared, never kept in user defaults or used, and
    /// `modelError` says why. One that is not a model ID (`OpenRouterProvider.isModelID(_:)`) is not kept or used
    /// either: `openrouter/auto` is. Unless no key is known to be stored, an entry is kept and used only once a read
    /// of the key, off the main actor, shows it does not contain the key (`keep(_:)`); while the key cannot be read,
    /// it is not, and it is checked again when whether a key is stored is next read.
    public var model: String {
        didSet {
            modelCheck?.cancel()
            modelCheck = nil
            if OpenRouterProvider.looksLikeKey(model) {
                refuseModel()
            } else {
                keep(model)
            }
            // The field shows what is committed, a cleared entry included.
            if modelEntry != model { modelEntry = model }
        }
    }
    /// Why the model ID entered was cleared, or is not used; set with `checkedModel` by each outcome of `keep(_:)`.
    public private(set) var modelError: String?
    /// The model ID requests use: the latest entry shown not to contain the key, or empty for `openrouter/auto`.
    /// User defaults hold only this, so a request never has an entry that was not checked.
    public private(set) var checkedModel: String

    @ObservationIgnored private let keys: OpenRouterKeyStore
    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log: any ExplainLog
    /// Counts key tests, Add key, and Remove key, so only the latest test is shown.
    @ObservationIgnored private var tests = 0
    /// The key test in flight; Add key and Remove key cancel it, so it sends nothing more with the key it read.
    @ObservationIgnored private var keyTestTask: Task<Void, Never>?
    /// Counts Add key and Remove key, so a presence read, or one of them, that a later one overtakes changes nothing.
    @ObservationIgnored private var keyChanges = 0
    /// The Add key and Remove key calls not finished yet. While there is one, no key is known not to be stored, and
    /// Settings does not offer Test key.
    private(set) var pendingKeyChanges = 0
    /// Makes the Keychain calls that store or remove the key, read whether one is stored, or read it for the key test
    /// or to check a model ID, one at a time in the order they are asked for and off the main actor, so a slow or
    /// prompting Keychain cannot hold the app, and what the Keychain holds after overlapping changes is what the last
    /// one asked for.
    @ObservationIgnored private let keychainQueue = DispatchQueue(label: "dev.subset.system.openrouter.keychain")
    /// The check of the model ID entered against the key stored.
    @ObservationIgnored private var modelCheck: Task<Void, Never>?
    /// Whether the latest check of the model ID entered could not read the key, so it is checked again.
    @ObservationIgnored private var modelUnchecked = false

    static let modelKey = "openRouterModel"
    public static let keyAsModelMessage = "That contains an API key, so it was cleared and not kept: openrouter/auto "
        + "is used. Add the key with Add Key."
    public static let modelUncheckedMessage = "The Keychain could not be read to check that this model ID does not "
        + "contain your API key, so it is not used or kept yet. It is checked again when Settings is next shown."
    public static let notAModelMessage = "That is not a model ID such as anthropic/claude-sonnet-4, so openrouter/auto "
        + "is used."
    public static let invalidKeyMessage = "That is not an API key: paste the whole key from openrouter.ai, with no spaces "
        + "inside it."

    /// The key in this Mac's Keychain, sent through an ephemeral session.
    public static func live() -> OpenRouterAccount {
        OpenRouterAccount(keys: OpenRouterKeyStore(), client: OpenRouterClient())
    }

    public init(keys: OpenRouterKeyStore, client: OpenRouterClient, defaults: UserDefaults = .standard,
                log: any ExplainLog = SystemExplainLog()) {
        self.keys = keys
        self.client = client
        self.defaults = defaults
        self.log = log
        let stored = (defaults.string(forKey: Self.modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let refused = !stored.isEmpty && !OpenRouterProvider.isModelID(stored)
        if refused { defaults.set("", forKey: Self.modelKey) }
        model = refused ? "" : stored
        modelEntry = refused ? "" : stored
        checkedModel = ""
        // Read off the main actor by `refreshKey()`, which the app calls at launch.
        presence = .unknown(shown: false)
        // Kept before, it is still checked against the key stored now before it is used.
        keep(model)
    }

    /// The provider for the model ID checked last (`checkedModel`).
    public func provider() -> OpenRouterProvider {
        OpenRouterProvider(keys: keys, model: checkedModel, client: client)
    }

    /// Stores `entered` as the key, replacing the one stored, off the main actor. Returns whether it was stored; an
    /// entry that cannot be a key is refused and nothing is stored. When a later Add key or Remove key is pressed
    /// before it finishes, what that one finds is what Settings shows.
    @discardableResult
    public func addKey(_ entered: String) async -> Bool {
        guard let key = OpenRouterKeyStore.normalized(entered) else {
            keyError = Self.invalidKeyMessage
            return false
        }
        let change = startKeyChange()
        defer { endKeyChange() }
        // A model ID entered or kept before that contains the key is neither kept nor used.
        if OpenRouterProvider.contains(key: key, in: model) { refuseModel() }
        if OpenRouterProvider.contains(key: key, in: checkedModel) {
            checkedModel = ""
            defaults.set("", forKey: Self.modelKey)
        }
        let saved = await onKeychainQueue { try $0.save(key) }
        pendingKeyChanges -= 1
        switch saved {
        case .success:
            log.record("OpenRouter key stored in the Keychain")
            guard change == keyChanges else { return true }
            presence = .stored
            keyError = nil
            return true
        case let .failure(error):
            log.record("OpenRouter key could not be stored")
            guard change == keyChanges else { return false }
            keyError = (error as? KeychainError)?.message ?? "The key could not be stored."
            // Whether a key is still stored: when that cannot be read either, it is not known, and what is shown stays.
            await reread(after: change, shown: hasKey)
            return false
        }
    }

    /// Removes the key from the Keychain, off the main actor. When a later Add key or Remove key is pressed before it
    /// finishes, what that one finds is what Settings shows.
    public func removeKey() async {
        let change = startKeyChange()
        defer { endKeyChange() }
        let removed = await onKeychainQueue { try $0.remove() }
        pendingKeyChanges -= 1
        switch removed {
        case .success:
            log.record("OpenRouter key removed from the Keychain")
            guard change == keyChanges else { return }
            presence = .absent
            keyError = nil
        case let .failure(error):
            log.record("OpenRouter key could not be removed")
            guard change == keyChanges else { return }
            keyError = (error as? KeychainError)?.message ?? "The key could not be removed."
            // Whether the key is still stored: when that cannot be read either, it is not known, and it is shown.
            await reread(after: change, shown: true)
        }
    }

    /// Starts Add key or Remove key: ends the key test, and Explain's OpenRouter work, in flight, and returns the
    /// change's number, so only the latest change, and a presence read made after it, set whether a key is stored.
    private func startKeyChange() -> Int {
        stopKeyTest()
        onKeyChange?()
        pendingKeyChanges += 1
        return keyChanges
    }

    /// Ends Add key or Remove key, once what it found is shown: when no other is in flight, that is reported
    /// (`onKeyChangeEnd`).
    private func endKeyChange() {
        if pendingKeyChanges == 0 { onKeyChangeEnd?() }
    }

    /// Reads again whether a key is stored, without reading the key, off the main actor: at launch and each time
    /// Settings is shown, so a Keychain read that failed once is not kept for the session. A read that Add key or
    /// Remove key overtakes changes nothing.
    public func refreshKey() async {
        let changes = keyChanges
        let read = await onKeychainQueue { try $0.containsKey() }
        guard changes == keyChanges else { return }
        switch read {
        case let .success(stored):
            if case .unknown = presence { keyError = nil }
            // A model ID that could not be checked against the key is checked again (`presence`).
            presence = stored ? .stored : .absent
        case let .failure(error):
            // Whether a key is stored is not known: what is shown stays.
            keyError = (error as? KeychainError)?.message ?? "The Keychain could not be read."
            presence = .unknown(shown: hasKey)
        }
    }

    /// Reads whether a key is stored after Add key or Remove key failed; a read that fails too leaves it not known. A
    /// read that a later Add key or Remove key overtakes changes nothing.
    private func reread(after change: Int, shown: Bool) async {
        let read = await onKeychainQueue { try $0.containsKey() }
        guard change == keyChanges else { return }
        switch read {
        case let .success(stored): presence = stored ? .stored : .absent
        case .failure: presence = .unknown(shown: shown)
        }
    }

    /// Makes `call` on the Keychain queue (`keychainQueue`), after every call asked for before it.
    private func onKeychainQueue<T: Sendable>(_ call: @escaping @Sendable (OpenRouterKeyStore) throws -> T) async
        -> Result<T, any Error> {
        let keys = self.keys
        return await withCheckedContinuation { continuation in
            keychainQueue.async { continuation.resume(returning: Result { try call(keys) }) }
        }
    }

    /// Ends the key test in flight, which used the key before this change: it is cancelled, so neither its request nor
    /// its retry is sent again, and nothing it finds is shown.
    private func stopKeyTest() {
        tests += 1
        keyChanges += 1
        keyTestTask?.cancel()
        keyTestTask = nil
        keyTest = nil
    }

    /// Uses and keeps `entered` (`checkedModel`). An empty entry, or one that is not a model ID, is not kept: it uses
    /// `openrouter/auto` at once. Unless no key is known to be stored, with no Add key or Remove key in flight, a
    /// non-empty entry is then compared with the key, read off the main actor after those calls: one that contains it
    /// is cleared (`keyAsModelMessage`), and a model ID that cannot be compared, because the key cannot be read, is not
    /// used or kept (`modelUncheckedMessage`), so what was checked before stays. A later entry ends the check. Each
    /// outcome sets the model ID used and its message together (`settle(using:error:unchecked:)`).
    private func keep(_ entered: String) {
        let candidate = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        let isModelID = OpenRouterProvider.isModelID(candidate)
        if candidate.isEmpty {
            settle(using: "", error: nil)
        } else if !isModelID {
            settle(using: "", error: Self.notAModelMessage)
        } else if presence == .absent, pendingKeyChanges == 0 {
            settle(using: candidate, error: nil)
        } else {
            // Until it is checked, what was checked before is used.
            settle(using: nil, error: nil)
        }
        guard !candidate.isEmpty, presence != .absent || pendingKeyChanges > 0 else { return }
        let task = Task {
            let read = await onKeychainQueue { try $0.readKey() }
            guard !Task.isCancelled, model == entered else { return }
            modelCheck = nil
            switch read {
            case let .success(key?) where OpenRouterProvider.contains(key: key, in: candidate):
                refuseModel()
            case .success:
                if isModelID { settle(using: candidate, error: nil) }
            case .failure where presence == .absent && pendingKeyChanges == 0:
                // The key was removed meanwhile: no key is known to be stored, so the entry is used as it is.
                keep(entered)
            case .failure:
                settle(using: isModelID ? nil : "", error: isModelID ? Self.modelUncheckedMessage : Self.notAModelMessage,
                       unchecked: true)
                if isModelID { onSetback?(.modelUnchecked) }
            }
        }
        modelCheck = task
    }

    /// Clears an entry that holds an API key: `openrouter/auto` is used and kept, and `keyAsModelMessage` says why.
    private func refuseModel() {
        modelCheck?.cancel()
        modelCheck = nil
        if !model.isEmpty { model = "" }
        settle(using: "", error: Self.keyAsModelMessage)
        onSetback?(.modelHeldKey)
    }

    /// Clears the model ID that a request was refused with because it holds the key stored now, as Explain reports it
    /// (`AIAvailability.openRouterModelHeldKey`), such as when the key was replaced outside System: like an entry
    /// that holds the key, it is neither kept nor used, and that is reported (`onSetback`). `sent` is the model ID the
    /// request had (`OpenRouterProvider.model`); once another one is used, it has been checked since, and stays.
    public func refuseModel(sent: String) {
        guard OpenRouterProvider.model(checkedModel) == sent else { return }
        refuseModel()
    }

    /// Applies one outcome of checking the model ID entered, in one step: the model ID used and kept (`nil` keeps what
    /// was checked before), the message Settings shows under it, and whether it is checked again once whether a key is
    /// stored is next known.
    private func settle(using checked: String?, error: String?, unchecked: Bool = false) {
        if let checked {
            checkedModel = checked
            defaults.set(checked, forKey: Self.modelKey)
        }
        modelError = error
        modelUnchecked = unchecked
    }

    /// Commits the Model field's entry (`modelEntry`): it is checked and kept as `model` says. Committing the entry
    /// committed already, as Return and then leaving the field do, checks nothing again.
    public func commitModel() {
        if modelEntry != model { model = modelEntry }
    }

    /// Waits for the model ID entered to be checked against the key and kept.
    func modelChecked() async {
        await modelCheck?.value
    }

    /// Sends the key test, which carries no user data (`OpenRouterClient.Request.keyTest`), and shows whether the key
    /// works or OpenRouter's error. A test that a later one, or Add key or Remove key, overtakes is not shown.
    /// The key is read after every Add key and Remove key pressed before the test, so it is the key they leave stored,
    /// or none; Add key and Remove key pressed after it cancel it: nothing more is sent with the key it read.
    public func testKey() async {
        keyTestTask?.cancel()
        tests += 1
        let test = tests
        keyTest = .testing
        let task = Task { await runKeyTest(test) }
        keyTestTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if test == tests { keyTestTask = nil }
    }

    private func runKeyTest(_ test: Int) async {
        let outcome: KeyTest?
        do {
            // Read off the main actor, so a slow or prompting Keychain cannot hold the app, and on the Keychain queue,
            // after the Add key and Remove key in flight, so a key being replaced or removed is never sent.
            let key = try await onKeychainQueue { try $0.readKey() }.get()
            // Add key or Remove key pressed after the test: what was read is not the key stored now, so it is not used.
            guard test == tests, !Task.isCancelled else { return }
            guard let key else {
                presence = .absent
                throw ExplainError.unavailable(.noOpenRouterKey)
            }
            presence = .stored
            _ = try await client.send(.keyTest, key: key)
            outcome = .passed
        } catch let error as ExplainError {
            outcome = .failed(error.message)
        } catch let error as KeychainError {
            // The key could not be read, so whether one is stored is not known.
            if test == tests { presence = .unknown(shown: hasKey) }
            outcome = .failed(error.message)
        } catch is CancellationError {
            outcome = nil
        } catch {
            outcome = .failed("The key test failed.")
        }
        guard test == tests else { return }
        keyTest = outcome
    }
}
