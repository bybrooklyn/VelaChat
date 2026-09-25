import XCTest
@testable import VelaCore

final class ProviderTokenCountRequestTests: XCTestCase {
    private let messages = [
        ChatMessage(role: "system", content: "Follow the project rules."),
        ChatMessage(role: "user", content: "Calculate 12 * 4."),
        ChatMessage(role: "assistant", content: "I will calculate it."),
    ]

    private var tool: ToolCatalog.Definition { ToolCatalog.calculator }

    func testOpenAICountBodyUsesResponsesInputAndFlatTools() throws {
        let data = try CompatibleChatClient.openAIInputTokenCountBody(
            model: "gpt-5",
            messages: messages,
            tools: [tool]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["role"] as? String, "system")
        let assistantContent = try XCTUnwrap(input[2]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.first?["type"] as? String, "input_text")

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, tool.name)
        XCTAssertNil(tools.first?["function"], "Responses tools are flat, not chat-completions wrappers")
    }

    func testAnthropicCountBodyUsesTopLevelSystemAndNativeToolSchema() throws {
        let data = try CompatibleChatClient.anthropicInputTokenCountBody(
            model: "claude-sonnet-5",
            messages: messages,
            tools: [tool]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let turns = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 2)
        XCTAssertFalse(turns.contains { ($0["role"] as? String) == "system" })
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "Follow the project rules.")
        XCTAssertNotNil(system.first?["cache_control"])

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, tool.name)
        XCTAssertNotNil(tools.first?["input_schema"])
        XCTAssertNil(tools.first?["function"])
    }

    func testGeminiCountBodyUsesGenerateContentShapeAndModelRole() throws {
        let data = try CompatibleChatClient.geminiInputTokenCountBody(
            model: "models/gemini-3-pro",
            messages: messages,
            tools: [tool]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(body["generateContentRequest"] as? [String: Any])
        XCTAssertNil(request["model"], "the model belongs only in the countTokens URL path")
        XCTAssertNotNil(request["systemInstruction"])
        let contents = try XCTUnwrap(request["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model"])

        let tools = try XCTUnwrap(request["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.first?["name"] as? String, tool.name)
        XCTAssertNotNil(declarations.first?["parameters"])
    }

    func testLogicalInputNormalizationDoesNotDoubleCountOpenAICache() {
        XCTAssertEqual(LogicalInputUsage.tokens(
            reportedInput: 1_000,
            cacheRead: 600,
            cacheWrite: 100,
            reportedInputIncludesCache: true
        ), 1_000)
    }

    func testLogicalInputNormalizationAddsAnthropicCacheLanes() {
        XCTAssertEqual(LogicalInputUsage.tokens(
            reportedInput: 300,
            cacheRead: 600,
            cacheWrite: 100,
            reportedInputIncludesCache: false
        ), 1_000)
        XCTAssertNil(LogicalInputUsage.tokens(
            reportedInput: nil,
            cacheRead: nil,
            cacheWrite: nil,
            reportedInputIncludesCache: false
        ))
    }


    func testPreparedRequestDeduplicatesToolsAndFingerprintsFinalPayload() {
        let profile = ProviderProfile(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .openAI,
            name: "OpenAI",
            endpoint: "https://api.openai.com/v1"
        )
        let first = PreparedRequest(
            profile: profile,
            requestedModel: "gpt-5",
            wireModel: "gpt-5",
            thinking: .medium,
            messages: messages,
            tools: [tool, tool],
            requestedOutputTokens: 8_192
        )
        let changed = PreparedRequest(
            profile: profile,
            requestedModel: "gpt-5",
            wireModel: "gpt-5",
            thinking: .medium,
            messages: messages + [ChatMessage(role: "user", content: "One more detail")],
            tools: [tool],
            requestedOutputTokens: 8_192
        )
        XCTAssertEqual(first.tools.count, 1)
        XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
        XCTAssertEqual(first.evidenceScope.endpointFingerprint, ModelEvidenceScope.fingerprint(endpoint: profile.endpoint))
    }
}
