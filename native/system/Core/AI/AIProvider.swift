/// Generates explanations: the on-device Apple Intelligence provider (SET-49) and OpenRouter (SET-50) behind the same
/// contract. A provider returns the model's answer unvalidated; `ExplainCenter` validates it.
public protocol AIProvider: Sendable {
    /// Whether it can answer now.
    func availability() async -> AIAvailability
    func explain(_ request: ExplainRequest) async throws -> ExplanationDraft
    /// As `explain(_:)`, calling `submitted` once the request is handed over to be sent off this Mac, so the send
    /// preview counts as used only once a body the user confirmed has actually gone out.
    func explain(_ request: ExplainRequest, submitted: @escaping @Sendable () -> Void) async throws -> ExplanationDraft
    /// Exactly what `explain(_:)` sends for `request`, as the send preview and What was sent show it.
    func sentText(for request: ExplainRequest) throws -> String
    /// Whether the user confirms what is sent before the first request of each app session: a provider off this Mac.
    var needsSendPreview: Bool { get }
}

extension AIProvider {
    public func explain(_ request: ExplainRequest,
                        submitted: @escaping @Sendable () -> Void) async throws -> ExplanationDraft {
        submitted()
        return try await explain(request)
    }
    public func sentText(for request: ExplainRequest) throws -> String { request.promptText }
    public var needsSendPreview: Bool { false }
}

/// The provider the user chose. By owner decision none is used until the user picks one, the on-device one included.
public enum AIProviderChoice: String, CaseIterable, Sendable {
    case none
    case appleIntelligence
    /// The user's own OpenRouter key: selectable only while one is stored (`ExplainCenter.choose(_:)`).
    case openRouter

    public var title: String {
        switch self {
        case .none: "None"
        case .appleIntelligence: "Apple Intelligence"
        case .openRouter: "OpenRouter"
        }
    }

    public var detail: String {
        switch self {
        case .none: "Explain is off. System works fully without it."
        case .appleIntelligence: "Generated on this Mac by Apple's on-device model. Nothing leaves this Mac."
        case .openRouter: "Sent to OpenRouter with your own API key, and from there to the model it routes to. Before "
            + "the first request of each session, System shows exactly what it will send and asks you to confirm."
        }
    }
}

/// Whether a provider can answer now, and what the user can do about it.
public enum AIAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// macOS reports another reason, added after this build.
    case unavailable
    /// macOS is older than 26.
    case requiresNewerMacOS
    /// This build was made without the FoundationModels framework.
    case notInThisBuild
    /// No OpenRouter key is stored.
    case noOpenRouterKey
    /// The Keychain did not return the stored OpenRouter key.
    case openRouterKeyUnreadable

    public var isAvailable: Bool { self == .available }

    public var title: String {
        switch self {
        case .available: "Available"
        case .deviceNotEligible: "This Mac cannot run Apple Intelligence"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .modelNotReady: "The model is not ready"
        case .unavailable: "Apple Intelligence is unavailable"
        case .requiresNewerMacOS: "Requires macOS 26"
        case .notInThisBuild: "Not in this build"
        case .noOpenRouterKey: "No OpenRouter key"
        case .openRouterKeyUnreadable: "The OpenRouter key could not be read"
        }
    }

    public var meaning: String {
        switch self {
        case .available: "Explain can answer now."
        case .deviceNotEligible: "Apple Intelligence needs a Mac with Apple silicon that supports it."
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri."
        case .modelNotReady: "macOS is still downloading or preparing the on-device model. Try again later."
        case .unavailable: "macOS reports that the on-device model cannot be used now."
        case .requiresNewerMacOS: "The on-device model is available from macOS 26."
        case .notInThisBuild: "This copy of System was built without Apple Intelligence support."
        case .noOpenRouterKey: "Add your OpenRouter API key in Settings."
        case .openRouterKeyUnreadable: "The Keychain did not return the key. Unlock this Mac, or remove the key and add "
            + "it again."
        }
    }
}

/// The instructions every provider gives the model before the request's facts.
public enum ExplainPrompt {
    public static let instructions = """
        You explain one item on the user's Mac: a process group, a process, a folder or file, a leftover of an app \
        that is no longer installed, or a reclaim suggestion. Use only the facts given and general knowledge of macOS \
        software; if they do not identify the item, say so and answer unknown rather than guess.
        Answer with:
        summary: one or two sentences, at most 280 characters.
        whatItIs: what the item is and what it does.
        removalSafety: likelySafe (rebuilt or no longer needed), review (may hold something the user wants), unsafe \
        (part of macOS or an app in use, or removal breaks something), or unknown.
        howToRemove: how to remove it properly, such as quitting the app, using its uninstaller or settings, removing \
        its login item, or moving the item to the Trash. Never suggest administrator commands or disabling macOS \
        security.
        confidence: low, medium, or high.
        suggestedOrigin: only when the facts say an origin may be suggested, the app, tool, or vendor it most likely \
        belongs to; otherwise leave it empty.
        Write plain text: no Markdown, HTML, links, or code blocks. Paths show the home folder as ~, and folder-… \
        names stand for folders whose names were withheld. Evidence lines name a kind of evidence, then the values it \
        names.
        """
}
