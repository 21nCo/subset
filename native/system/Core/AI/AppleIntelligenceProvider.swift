import Foundation
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

    /// Answers an Ask question in a new session given Ask's tools; nothing leaves this Mac, so `gate` is not used.
    public func ask(_ prompt: AskPrompt, tools: AskTools, gate _: AskSendGate) async throws -> String {
        let availability = await availability()
        guard availability.isAvailable else { throw ExplainError.unavailable(availability) }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(tools: AskModelTools.all(tools), instructions: AskPrompt.instructions)
            do {
                return try await session.respond(to: prompt.text).content
            } catch let error as LanguageModelSession.GenerationError {
                throw ExplainError(error, declined: "Apple Intelligence declined to answer this question.")
            } catch is LanguageModelSession.ToolCallError {
                throw ExplainError.failed("Apple Intelligence could not use System's tools to answer.")
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
    init(_ error: LanguageModelSession.GenerationError,
         declined: String = "Apple Intelligence declined to explain this item.") {
        switch error {
        case .assetsUnavailable: self = .unavailable(.modelNotReady)
        case .guardrailViolation, .refusal: self = .failed(declined)
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

#if canImport(FoundationModels)
/// Ask's tools as FoundationModels tools: each forwards its arguments, as JSON, to the toolbox, which validates and runs
/// them as it does OpenRouter's.
@available(macOS 26, *)
enum AskModelTools {
    static func all(_ tools: AskTools) -> [any Tool] {
        [
            AskModelTool<TopGroupsArguments>(tool: .topGroups, tools: tools),
            AskModelTool<GroupDetailArguments>(tool: .groupDetail, tools: tools),
            AskModelTool<NoArguments>(tool: .memoryState, tools: tools),
            AskModelTool<NoArguments>(tool: .diskSummary, tools: tools),
            AskModelTool<LargestItemsArguments>(tool: .largestItems, tools: tools),
            AskModelTool<NoArguments>(tool: .reclaimSuggestions, tools: tools)
        ]
    }
}

@available(macOS 26, *)
protocol AskModelArguments: Generable {
    var json: [String: Any] { get }
}

@available(macOS 26, *)
struct AskModelTool<Arguments: AskModelArguments>: Tool {
    let tool: AskTool
    let tools: AskTools

    var name: String { tool.rawValue }
    var description: String { tool.summary }

    func call(arguments: Arguments) async throws -> String {
        let data = (try? JSONSerialization.data(withJSONObject: arguments.json)) ?? Data("{}".utf8)
        return await tools.call(tool.rawValue, arguments: data)
    }
}

@available(macOS 26, *)
@Generable
struct TopGroupsArguments: AskModelArguments {
    @Guide(description: "What to order groups by", .anyOf(AskMetric.allCases.map(\.rawValue)))
    var metric: String
    @Guide(description: "How processes are grouped", .anyOf(AttributionLayer.allCases.map(\.rawValue)))
    var layer: String
    @Guide(description: "How many groups", .range(1...10))
    var limit: Int

    var json: [String: Any] { ["metric": metric, "layer": layer, "limit": limit] }
}

@available(macOS 26, *)
@Generable
struct GroupDetailArguments: AskModelArguments {
    @Guide(description: "A group id a tool returned, like g1")
    var id: String

    var json: [String: Any] { ["id": id] }
}

@available(macOS 26, *)
@Generable
struct LargestItemsArguments: AskModelArguments {
    @Guide(description: "How many items", .range(1...20))
    var limit: Int

    var json: [String: Any] { ["limit": limit] }
}

@available(macOS 26, *)
@Generable
struct NoArguments: AskModelArguments {
    var json: [String: Any] { [:] }
}
#endif
