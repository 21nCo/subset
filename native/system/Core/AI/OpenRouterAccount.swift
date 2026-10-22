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
    /// The model ID as the user entered it; empty sends `openrouter/auto` (`OpenRouterProvider.model(_:)`).
    public var model: String {
        didSet { defaults.set(model, forKey: Self.modelKey) }
    }

    /// Called once a key is removed, so the provider setting stops being OpenRouter.
    @ObservationIgnored var onKeyRemoved: (() -> Void)?
    @ObservationIgnored private let keys: OpenRouterKeyStore
    @ObservationIgnored private let client: OpenRouterClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log: any ExplainLog
    /// Counts key tests, so only the latest one is shown.
    @ObservationIgnored private var tests = 0

    static let modelKey = "openRouterModel"
    public static let invalidKeyMessage = "That is not an API key: paste the whole key from openrouter.ai, with no spaces "
        + "inside it."

    public init(keys: OpenRouterKeyStore, client: OpenRouterClient, defaults: UserDefaults = .standard,
                log: any ExplainLog = SystemExplainLog()) {
        self.keys = keys
        self.client = client
        self.defaults = defaults
        self.log = log
        model = defaults.string(forKey: Self.modelKey) ?? ""
        do {
            hasKey = try keys.containsKey()
        } catch let error as KeychainError {
            hasKey = false
            keyError = error.message
        } catch {
            hasKey = false
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
        tests += 1
        keyTest = nil
        do {
            try keys.save(key)
            hasKey = true
            keyError = nil
            log.record("OpenRouter key stored in the Keychain")
            return true
        } catch {
            keyError = (error as? KeychainError)?.message ?? "The key could not be stored."
            hasKey = (try? keys.containsKey()) ?? false
            log.record("OpenRouter key could not be stored")
            return false
        }
    }

    /// Removes the key from the Keychain; the provider setting then stops being OpenRouter.
    public func removeKey() {
        tests += 1
        keyTest = nil
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

    /// Sends the key test, which carries no user data (`OpenRouterClient.Request.keyTest`), and shows whether the key
    /// works or OpenRouter's error. A test that a later one, or Add key or Remove key, overtakes is not shown.
    public func testKey() async {
        tests += 1
        let test = tests
        keyTest = .testing
        let outcome: KeyTest?
        do {
            guard let key = try keys.readKey() else {
                hasKey = false
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
