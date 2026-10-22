#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model through FoundationModels: compiled only when the SDK has the framework and used only on
/// macOS 26 or later, so System still builds and runs from macOS 14. Each request gets a new session, so nothing
/// carries over between items.
public struct AppleIntelligenceProvider: AIProvider {
    public init() {}

    public func availability() async -> AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return AIAvailability(SystemLanguageModel.default.availability)
        }
        return .requiresNewerMacOS
        #else
        return .notInThisBuild
        #endif
    }

    public func explain(_ request: ExplainRequest) async throws -> ExplanationDraft {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: ExplainPrompt.instructions)
            do {
                let answer = try await session.respond(to: request.promptText, generating: GeneratedExplanation.self)
                return answer.content.draft
            } catch let error as LanguageModelSession.GenerationError {
                throw ExplainError(error)
            }
        }
        throw ExplainError.unavailable(.requiresNewerMacOS)
        #else
        throw ExplainError.unavailable(.notInThisBuild)
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
extension AIAvailability {
    /// What FoundationModels reports, as System shows it.
    public init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available: self = .available
        case .unavailable(.deviceNotEligible): self = .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): self = .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): self = .modelNotReady
        // A reason added in a later macOS.
        case .unavailable: self = .unavailable
        }
    }
}

@available(macOS 26, *)
extension ExplainError {
    init(_ error: LanguageModelSession.GenerationError) {
        switch error {
        case .assetsUnavailable: self = .unavailable(.modelNotReady)
        case .guardrailViolation, .refusal: self = .failed("Apple Intelligence declined to explain this item.")
        case .exceededContextWindowSize: self = .failed("The request was too long for the on-device model.")
        case .decodingFailure: self = .invalidResponse("The on-device model's answer did not fit the schema.")
        default: self = .failed("Apple Intelligence could not answer: \(error.localizedDescription)")
        }
    }
}

@available(macOS 26, *)
@Generable(description: "An explanation of one item on a Mac")
struct GeneratedExplanation {
    @Guide(description: "One or two plain sentences, at most 280 characters")
    var summary: String
    @Guide(description: "What the item is and what it does, in plain text")
    var whatItIs: String
    var removalSafety: GeneratedRemovalSafety
    @Guide(description: "How to remove it properly, in plain text")
    var howToRemove: String
    var confidence: GeneratedConfidence
    @Guide(description: "Only when an origin may be suggested: the app, tool, or vendor it most likely belongs to")
    var suggestedOrigin: String?

    var draft: ExplanationDraft {
        ExplanationDraft(summary: summary, whatItIs: whatItIs, removalSafety: removalSafety.value.rawValue,
                         howToRemove: howToRemove, confidence: confidence.value.rawValue, suggestedOrigin: suggestedOrigin)
    }
}

@available(macOS 26, *)
@Generable
enum GeneratedRemovalSafety {
    case likelySafe, review, unsafe, unknown

    var value: RemovalSafety {
        switch self {
        case .likelySafe: .likelySafe
        case .review: .review
        case .unsafe: .unsafe
        case .unknown: .unknown
        }
    }
}

@available(macOS 26, *)
@Generable
enum GeneratedConfidence {
    case low, medium, high

    var value: ExplanationConfidence {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}
#endif
