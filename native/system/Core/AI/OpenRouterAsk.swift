import Foundation

/// Ask (SET-51) through OpenRouter: chat completions with Ask's tools as functions. Each request's body goes through
/// the send gate first, so it is previewed as Explain's are, and is kept (`AskSendGate.sending`) as it is handed to the
/// client, before OpenRouter answers it (`AskSendGate.answered`, as its first HTTP answer comes, before any retry) or
/// the send fails; tool results, redacted by the
/// toolbox, go back in the next request. After `AskToolbox.callLimit` calls the request asks for an answer with
/// `tool_choice` `none`, so a question takes at most `callLimit + 1` requests. A batch of tool calls larger than what is
/// left of the question's `AskToolbox.budgetedCalls` runs none of them, and a call the toolbox refuses to return from
/// ends the batch: either way the question fails with `AskToolbox.exhausted`, and nothing more is sent. The key is read
/// for each request, each read one of the checks shared with Explain (`AskSendGate.check()`), and must be the one read
/// as the question began, so a key replaced meanwhile is never used; a read that finds it cannot be used throws
/// `AskKeyRefusal`, and nothing is sent.
extension OpenRouterProvider {
    public func ask(_ prompt: AskPrompt, tools: AskTools, gate: AskSendGate) async throws -> String {
        let checked = OpenRouterKeyIdentity(try await sendingKey(gate))
        if let checkedKey, checkedKey != checked { throw ExplainError.failed(Self.keyChanged) }
        var messages: [[String: Any]] = [["role": "system", "content": AskPrompt.instructions]]
        for turn in prompt.history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": prompt.question])
        var calls = 0
        for _ in 0...AskToolbox.callLimit {
            let toolsAllowed = calls < AskToolbox.callLimit
            let body = try askBody(messages, toolsAllowed: toolsAllowed)
            let confirmed = try await gate.confirm(body)
            let key = try await sendingKey(gate)
            guard OpenRouterKeyIdentity(key) == checked else { throw ExplainError.failed(Self.keyChanged) }
            let data: Data
            await gate.sending(body)
            do {
                // OpenRouter's first HTTP answer shows it has the body, the one a retry follows included.
                data = try await client.send(.chat(body), key: key) { await gate.answered(body, confirmed: confirmed) }
            } catch let ExplainError.failed(message) where message.hasPrefix(Self.answeredPrefix) {
                throw ExplainError.rejected(message)
            }
            let message = try Self.message(from: data, key: key)
            if let refusal = message["refusal"] as? String, !refusal.isEmpty {
                throw ExplainError.rejected("The model declined to answer this question.")
            }
            if let requested = try Self.toolCalls(in: message) {
                guard toolsAllowed else {
                    throw ExplainError.invalidResponse("The model asked for more tools after its \(AskToolbox.callLimit).")
                }
                guard requested.count <= AskToolbox.budgetedCalls - calls else { throw AskToolbox.exhausted }
                messages.append(["role": "assistant", "content": message["content"] as? String ?? NSNull(),
                                 "tool_calls": requested.map(\.json)])
                for call in requested {
                    calls += 1
                    let result = try await tools.call(call.name, arguments: Data(call.arguments.utf8))
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
                }
                continue
            }
            guard let content = message["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExplainError.invalidResponse("OpenRouter's answer has no content.")
            }
            return content
        }
        throw ExplainError.invalidResponse("The model did not answer after \(AskToolbox.callLimit) tool calls.")
    }

    /// The JSON body of one Ask request: its bytes are the same each time it is built.
    func askBody(_ messages: [[String: Any]], toolsAllowed: Bool) throws -> Data {
        let functions = AskTool.allCases.map { tool -> [String: Any] in
            ["type": "function",
             "function": ["name": tool.rawValue, "description": tool.summary, "parameters": tool.schema]]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": functions,
            "tool_choice": toolsAllowed ? "auto" : "none",
            // Routes only to providers that support tool calls.
            "provider": ["require_parameters": true]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// The key a request is sent with, read as a check taken just before (`AskSendGate.check()`): not when it cannot be
    /// read, none is stored, or the model ID holds it, so nothing is sent then.
    private func sendingKey(_ gate: AskSendGate) async throws -> String {
        let check = try await gate.check()
        let key: String?
        do {
            key = try keys.readKey()
        } catch {
            throw AskKeyRefusal(availability: .openRouterKeyUnreadable, check: check)
        }
        guard let key else { throw AskKeyRefusal(availability: .noOpenRouterKey, check: check) }
        guard !Self.contains(key: key, in: model) else {
            throw AskKeyRefusal(availability: .openRouterModelHeldKey, check: check)
        }
        return key
    }

    struct ToolCall {
        let id: String
        let name: String
        let arguments: String

        var json: [String: Any] {
            ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
        }
    }

    /// The message's tool calls, or `nil` when it has none. A call without an id, a function name, or text arguments
    /// is outside the format, and so is the whole answer.
    static func toolCalls(in message: [String: Any]) throws -> [ToolCall]? {
        guard let raw = message["tool_calls"], !(raw is NSNull) else { return nil }
        guard let list = raw as? [Any] else { throw ExplainError.invalidResponse("OpenRouter's tool calls are not a list.") }
        guard !list.isEmpty else { return nil }
        return try list.map { item in
            guard let call = item as? [String: Any], let id = call["id"] as? String, !id.isEmpty,
                  let function = call["function"] as? [String: Any], let name = function["name"] as? String else {
                throw ExplainError.invalidResponse("OpenRouter's answer has a tool call System cannot read.")
            }
            let arguments = function["arguments"].flatMap { $0 is NSNull ? nil : $0 }
            guard arguments == nil || arguments is String else {
                throw ExplainError.invalidResponse("OpenRouter's answer has a tool call System cannot read.")
            }
            return ToolCall(id: id, name: name, arguments: arguments as? String ?? "")
        }
    }
}

/// An Ask key read that found OpenRouter cannot be used, with the check it took (`OpenRouterChecks`), so only the latest
/// check sets the choice back (`ExplainCenter.refused(_:check:from:)`).
struct AskKeyRefusal: Error {
    let availability: AIAvailability
    let check: Int
}
