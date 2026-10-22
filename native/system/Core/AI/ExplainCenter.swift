import Foundation
import Observation

/// Identifies an item to explain across samples and scans: a group's or process's identity, or a scanned path.
public struct ExplainKey: Hashable, Sendable {
    public let id: String

    public init(_ id: String) {
        self.id = id
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
}

/// The Explain setting and each item's explanation. Nothing is sent until the user picks a provider (`choice` starts
/// as `.none`, and with `.none` no provider is made or called). Explanations are kept in memory for the session, per
/// provider and item; a failed or unavailable one can be asked again.
@MainActor
@Observable
public final class ExplainCenter {
    public var choice: AIProviderChoice {
        didSet {
            guard choice != oldValue else { return }
            defaults.set(choice.rawValue, forKey: Self.choiceKey)
            availability = nil
        }
    }
    /// Sends folder names deeper than the first level under `~` instead of placeholders. Off by default.
    public var sendFolderNames: Bool {
        didSet { defaults.set(sendFolderNames, forKey: Self.sendFolderNamesKey) }
    }
    /// The chosen provider's availability when last read; `nil` before that and for `.none`.
    public private(set) var availability: AIAvailability?
    private var states: [StateKey: ExplainState] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeProvider: @MainActor (AIProviderChoice) -> (any AIProvider)?
    @ObservationIgnored private let baseRedactor: ExplainRedactor

    static let choiceKey = "explainProvider"
    static let sendFolderNamesKey = "explainSendFolderNames"

    private struct StateKey: Hashable {
        let choice: AIProviderChoice
        let item: ExplainKey
    }

    public init(defaults: UserDefaults = .standard, redactor: ExplainRedactor,
                provider: @escaping @MainActor (AIProviderChoice) -> (any AIProvider)? = ExplainCenter.liveProvider) {
        self.defaults = defaults
        baseRedactor = redactor
        makeProvider = provider
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

    /// Reads the chosen provider's availability, for Settings.
    public func refreshAvailability() async {
        let choice = self.choice
        guard choice != .none, let provider = makeProvider(choice) else { return }
        let availability = await provider.availability()
        if choice == self.choice { self.availability = availability }
    }

    /// Explains an item with the chosen provider, building its request with the current redactor. Does nothing without
    /// a provider, while the item is being explained, or once it has been. Returns when the answer is in.
    public func explain(_ item: ExplainKey, request build: (ExplainRedactor) -> ExplainRequest?) async {
        let choice = self.choice
        let key = StateKey(choice: choice, item: item)
        switch states[key] {
        case .working?, .explained?: return
        default: break
        }
        guard choice != .none, let provider = makeProvider(choice), let request = build(redactor) else { return }
        states[key] = .working(request)
        let availability = await provider.availability()
        if choice == self.choice { self.availability = availability }
        guard availability.isAvailable else {
            states[key] = .unavailable(availability)
            return
        }
        do {
            let draft = try await provider.explain(request)
            states[key] = .explained(try Explanation(validating: draft, for: request), request)
        } catch let ExplainError.unavailable(availability) {
            states[key] = .unavailable(availability)
        } catch let error as ExplainError {
            states[key] = .failed(error.message, request)
        } catch is CancellationError {
            states[key] = nil
        } catch {
            states[key] = .failed(error.localizedDescription, request)
        }
    }
}
