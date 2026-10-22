import Foundation
import Observation

/// The OpenRouter part of Settings: **Add key**, **Test key**, **Remove key**, and the model ID. Only whether a key is
/// stored is kept here; the key itself stays in the Keychain (`OpenRouterKeyStore`) and is read only to send a request
/// or the key test. The model ID is kept in user defaults; the key never is.
@MainActor
@Observable
public final class OpenRouterAccount {
    /// Where the latest key test stands.
    public enum KeyTest: Equatable, Sendable {
        case testing
        case passed
        case failed(String)
    }

    public private(set) var hasKey: Bool
    /// Why the latest Add key, Remove key, or Keychain read failed; cleared by the next one that works.
    public private(set) var keyError: String?
    public private(set) var keyTest: KeyTest?
    /// The model ID as the user entered it; empty sends `openrouter/auto` (`OpenRouterProvider.model(_:)`). An entry
    /// that looks like an API key, or is the key stored, whichever was entered first, is refused: it is cleared, never
    /// kept in user defaults, and `modelError` says why. While a key is stored, an entry is kept in user defaults only
    /// once it is checked against the key, off the main actor (`checkModel(_:)`).
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
    /// Why the model ID entered was cleared; cleared by the next one kept.
    public private(set) var modelError: String?

    /// Called once a key is removed, or found no longer stored, so the provider setting stops being OpenRouter.
    @ObservationIgnored var onKeyRemoved: (() -> Void)?
    /// Called on each Add key and Remove key, before the Keychain is changed.
    @ObservationIgnored var onKeyChange: (() -> Void)?
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
    /// Whether the latest read of whether a key is stored failed, so that is not known; `keyError` is then its
    /// failure, which the next read that works clears.
    @ObservationIgnored private(set) var presenceFailed = false
    /// The check of the model ID entered against the key stored.
    @ObservationIgnored private var modelCheck: Task<Void, Never>?

    static let modelKey = "openRouterModel"
    public static let keyAsModelMessage = "That looks like an API key, not a model ID, so it was cleared and not "
        + "kept: openrouter/auto is used. Add the key with Add Key."
    public static let invalidKeyMessage = "That is not an API key: paste the whole key from openrouter.ai, with no spaces "
        + "inside it."

    public init(keys: OpenRouterKeyStore, client: OpenRouterClient, defaults: UserDefaults = .standard,
                log: any ExplainLog = SystemExplainLog()) {
        self.keys = keys
        self.client = client
        self.defaults = defaults
        self.log = log
        let stored = defaults.string(forKey: Self.modelKey) ?? ""
        let refused = OpenRouterProvider.looksLikeKey(stored)
        if refused { defaults.set("", forKey: Self.modelKey) }
        model = refused ? "" : stored
        do {
            hasKey = try keys.containsKey()
        } catch {
            hasKey = false
            keyError = (error as? KeychainError)?.message ?? "The Keychain could not be read."
            presenceFailed = true
        }
    }

    /// The provider for the model ID set now.
    public func provider() -> OpenRouterProvider {
        OpenRouterProvider(keys: keys, model: model, client: client)
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
        // A key entered as the model ID before is not kept there.
        if model.trimmingCharacters(in: .whitespacesAndNewlines) == key {
            model = ""
            modelError = Self.keyAsModelMessage
        }
        do {
            try keys.save(key)
            hasKey = true
            keyError = nil
            presenceFailed = false
            log.record("OpenRouter key stored in the Keychain")
            return true
        } catch {
            keyError = (error as? KeychainError)?.message ?? "The key could not be stored."
            presenceFailed = false
            // Whether a key is still stored: when that cannot be read either, what is shown stays.
            if let stored = try? keys.containsKey(), stored != hasKey {
                hasKey = stored
                if !stored { onKeyRemoved?() }
            }
            log.record("OpenRouter key could not be stored")
            return false
        }
    }

    /// Removes the key from the Keychain; the provider setting then stops being OpenRouter.
    public func removeKey() {
        stopKeyTest()
        presenceFailed = false
        do {
            try keys.remove()
            hasKey = false
            keyError = nil
            log.record("OpenRouter key removed from the Keychain")
        } catch {
            keyError = (error as? KeychainError)?.message ?? "The key could not be removed."
            hasKey = (try? keys.containsKey()) ?? true
            log.record("OpenRouter key could not be removed")
        }
        if !hasKey { onKeyRemoved?() }
    }

    /// Reads again whether a key is stored, without reading the key, off the main actor: each time Settings is shown
    /// and when the user checks the provider again, so a Keychain read that failed once is not kept for the session.
    /// A read that Add key or Remove key overtakes changes nothing; a key no longer stored turns OpenRouter off.
    public func refreshKey() async {
        let changes = keyChanges
        let keys = self.keys
        let read = await Task.detached { Result { try keys.containsKey() } }.value
        guard changes == keyChanges else { return }
        switch read {
        case let .success(stored):
            if presenceFailed { keyError = nil }
            presenceFailed = false
            if hasKey, !stored {
                hasKey = false
                onKeyRemoved?()
            } else {
                hasKey = stored
            }
        case let .failure(error):
            // Whether a key is stored is not known: what is shown stays.
            keyError = (error as? KeychainError)?.message ?? "The Keychain could not be read."
            presenceFailed = true
        }
    }

    /// Ends the key test in flight, which used the key before this change: it is cancelled, so neither its request nor
    /// its retry is sent again, and nothing it finds is shown.
    private func stopKeyTest() {
        tests += 1
        keyChanges += 1
        onKeyChange?()
        keyTestTask?.cancel()
        keyTestTask = nil
        keyTest = nil
    }

    /// Keeps `entered` in user defaults. While a key is stored, a non-empty entry is first compared with it off the
    /// main actor; one that is the key is cleared instead (`keyAsModelMessage`). A later entry ends the check.
    private func keep(_ entered: String) {
        let candidate = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasKey, !candidate.isEmpty else {
            defaults.set(entered, forKey: Self.modelKey)
            return
        }
        let keys = self.keys
        modelCheck = Task {
            let key = await Task.detached { try? keys.readKey() }.value
            guard !Task.isCancelled, model == entered else { return }
            if key == candidate {
                model = ""
                modelError = Self.keyAsModelMessage
            } else {
                defaults.set(entered, forKey: Self.modelKey)
            }
        }
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
                if hasKey {
                    hasKey = false
                    onKeyRemoved?()
                }
                throw ExplainError.unavailable(.noOpenRouterKey)
            }
            _ = try await client.send(.keyTest, key: key)
            outcome = .passed
        } catch let error as ExplainError {
            outcome = .failed(error.message)
        } catch let error as KeychainError {
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
