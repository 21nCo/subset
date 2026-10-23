import Foundation
import Observation

/// The OpenRouter part of Settings: **Add key**, **Test key**, **Remove key**, and the model ID. Only whether a key is
/// stored is kept here; the key itself stays in the Keychain (`OpenRouterKeyStore`) and is read, off the main actor, only
/// to send a request or the key test and, unless no key is known to be stored (`presence`), to check that a model ID
/// entered does not contain it. The model ID is kept in user defaults; the key never is. Explain does not use
/// OpenRouter yet: SET-160 adds it to the provider setting, with the send preview, through `provider()`.
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
        /// The latest read of it failed; `shown` is whether Settings shows a key stored meanwhile.
        case unknown(shown: Bool)
    }

    /// Set by every read of whether a key is stored, and by Add key, Remove key and the key test. A model ID entry is
    /// kept without comparing it with the key only while this is `absent`.
    public private(set) var presence: KeyPresence
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
    /// The model ID as the user entered it. An entry with an API key anywhere in it (`sk-or-`, or the key stored,
    /// whichever was entered first) is refused: it is cleared, never kept in user defaults or used, and `modelError`
    /// says why. One that is not a model ID (`OpenRouterProvider.isModelID(_:)`) is not kept or used either:
    /// `openrouter/auto` is. Unless no key is known to be stored, an entry is kept and used only once a read of the
    /// key, off the main actor, shows it does not contain the key (`keep(_:)`); while the key cannot be read, it is
    /// not, and it is checked again when whether a key is stored is next read.
    public var model: String {
        didSet {
            modelCheck?.cancel()
            modelCheck = nil
            if OpenRouterProvider.looksLikeKey(model) {
                model = ""
                modelError = Self.keyAsModelMessage
            } else if !model.isEmpty {
                modelError = nil
            }
            keep(model)
        }
    }
    /// Why the model ID entered was cleared, or is not used; cleared by the next one kept.
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
    /// Counts Add key and Remove key, so a presence read they overtake changes nothing.
    @ObservationIgnored private var keyChanges = 0
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
        checkedModel = ""
        do {
            presence = try keys.containsKey() ? .stored : .absent
        } catch {
            presence = .unknown(shown: false)
            keyError = (error as? KeychainError)?.message ?? "The Keychain could not be read."
        }
        // Kept before, it is still checked against the key stored now before it is used.
        keep(model)
    }

    /// The provider for the model ID checked last (`checkedModel`).
    public func provider() -> OpenRouterProvider {
        OpenRouterProvider(keys: keys, model: checkedModel, client: client)
    }

    /// Stores `entered` as the key, replacing the one stored. Returns whether it was stored; an entry that cannot be a
    /// key is refused and nothing is stored.
    @discardableResult
    public func addKey(_ entered: String) -> Bool {
        guard let key = OpenRouterKeyStore.normalized(entered) else {
            keyError = Self.invalidKeyMessage
            return false
        }
        stopKeyTest()
        // A model ID entered or kept before that contains the key is neither kept nor used.
        if OpenRouterProvider.contains(key: key, in: model) {
            model = ""
            modelError = Self.keyAsModelMessage
        }
        if OpenRouterProvider.contains(key: key, in: checkedModel) {
            checkedModel = ""
            defaults.set("", forKey: Self.modelKey)
        }
        do {
            try keys.save(key)
            presence = .stored
            keyError = nil
            log.record("OpenRouter key stored in the Keychain")
            return true
        } catch {
            keyError = (error as? KeychainError)?.message ?? "The key could not be stored."
            // Whether a key is still stored: when that cannot be read either, it is not known, and what is shown stays.
            reread(shown: hasKey)
            log.record("OpenRouter key could not be stored")
            return false
        }
    }

    /// Removes the key from the Keychain.
    public func removeKey() {
        stopKeyTest()
        do {
            try keys.remove()
            presence = .absent
            keyError = nil
            log.record("OpenRouter key removed from the Keychain")
        } catch {
            keyError = (error as? KeychainError)?.message ?? "The key could not be removed."
            // Whether the key is still stored: when that cannot be read either, it is not known, and it is shown.
            reread(shown: true)
            log.record("OpenRouter key could not be removed")
        }
    }

    /// Reads again whether a key is stored, without reading the key, off the main actor: each time Settings is shown,
    /// so a Keychain read that failed once is not kept for the session. A read that Add key or Remove key overtakes
    /// changes nothing.
    public func refreshKey() async {
        let changes = keyChanges
        let keys = self.keys
        let read = await Task.detached { Result { try keys.containsKey() } }.value
        guard changes == keyChanges else { return }
        switch read {
        case let .success(stored):
            if case .unknown = presence { keyError = nil }
            presence = stored ? .stored : .absent
            // A model ID that could not be checked against the key is checked again.
            if modelUnchecked, modelCheck == nil { keep(model) }
        case let .failure(error):
            // Whether a key is stored is not known: what is shown stays.
            keyError = (error as? KeychainError)?.message ?? "The Keychain could not be read."
            presence = .unknown(shown: hasKey)
        }
    }

    /// Reads whether a key is stored after Add key or Remove key failed; a read that fails too leaves it not known.
    private func reread(shown: Bool) {
        do {
            presence = try keys.containsKey() ? .stored : .absent
        } catch {
            presence = .unknown(shown: shown)
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
    /// `openrouter/auto` at once. Unless no key is known to be stored, a non-empty entry is then compared with the key,
    /// read off the main actor: one that contains it is cleared (`keyAsModelMessage`), and a model ID that cannot be
    /// compared, because the key cannot be read, is not used or kept (`modelUncheckedMessage`), so what was checked
    /// before stays. A later entry ends the check.
    private func keep(_ entered: String) {
        let candidate = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        let isModelID = OpenRouterProvider.isModelID(candidate)
        modelUnchecked = false
        if !isModelID {
            use("")
            if !candidate.isEmpty { modelError = Self.notAModelMessage }
        }
        guard !candidate.isEmpty, presence != .absent else {
            if isModelID { use(candidate) }
            return
        }
        let keys = self.keys
        let task = Task {
            let read = await Task.detached { Result { try keys.readKey() } }.value
            guard !Task.isCancelled, model == entered else { return }
            modelCheck = nil
            switch read {
            case let .success(key?) where OpenRouterProvider.contains(key: key, in: candidate):
                model = ""
                modelError = Self.keyAsModelMessage
            case .success:
                guard isModelID else { return }
                if modelError == Self.modelUncheckedMessage { modelError = nil }
                use(candidate)
            case .failure:
                modelUnchecked = true
                if isModelID { modelError = Self.modelUncheckedMessage }
            }
        }
        modelCheck = task
    }

    private func use(_ checked: String) {
        checkedModel = checked
        defaults.set(checked, forKey: Self.modelKey)
    }

    /// Waits for the model ID entered to be checked against the key and kept.
    func modelChecked() async {
        await modelCheck?.value
    }

    /// Sends the key test, which carries no user data (`OpenRouterClient.Request.keyTest`), and shows whether the key
    /// works or OpenRouter's error. A test that a later one, or Add key or Remove key, overtakes is not shown.
    /// Add key and Remove key cancel it: once either is pressed, nothing more is sent with the key it read.
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
            // Read off the main actor, as a request reads it, so a slow or prompting Keychain cannot hold the app.
            let keys = self.keys
            let key = try await Task.detached(operation: { try keys.readKey() }).value
            // Add key or Remove key while it was read: what was read is not the key stored now, so it is not used.
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
