import XCTest
@testable import VelaCore

/// OpenRouter catalog shapes, pinned against the live API (fetched
/// 2026-09-25; trimmed to the fields the mapping reads). The mapping must
/// prefer `top_provider` deployment figures over the model-level ones.
final class OpenRouterCatalogTests: XCTestCase {
    /// Shape of `GET /api/v1/model/:slug` — same Item as the bulk list,
    /// wrapped in a `data` object.
    private let singleModelJSON = """
    {"data":{"id":"openai/gpt-4o","canonical_slug":"openai/gpt-4o","name":"OpenAI: GPT-4o","description":"Flagship multimodal model.","context_length":128000,"architecture":{"modality":"text+image->text","input_modalities":["text","image"]},"pricing":{"prompt":"0.0000025","completion":"0.00001"},"top_provider":{"context_length":128000,"max_completion_tokens":16384,"is_moderated":true},"supported_parameters":["tools","temperature","max_tokens"]}}
    """

    func testSingleModelResponseDecodes() throws {
        let decoded = try JSONDecoder().decode(
            SingleModelResponse.self, from: Data(singleModelJSON.utf8)
        )
        XCTAssertEqual(decoded.data.id, "openai/gpt-4o")
        XCTAssertEqual(decoded.data.topProvider?.maxCompletionTokens, 16384)
    }

    func testMappingPrefersTopProviderDeploymentFigures() throws {        let decoded = try JSONDecoder().decode(
            SingleModelResponse.self, from: Data(singleModelJSON.utf8)
        )
        let profile = ProviderProfile(kind: .openRouter, name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1")
        let model = CompatibleChatClient.remoteModel(from: decoded.data, profile: profile)
        XCTAssertEqual(model.id, "openai/gpt-4o")
        XCTAssertEqual(model.contextLength, 128000)
        XCTAssertEqual(model.maxOutputTokens, 16384)
        XCTAssertEqual(model.inputPricePerMillion, 2.5, accuracy: 0.0001)
        XCTAssertEqual(model.outputPricePerMillion, 10, accuracy: 0.0001)
        XCTAssertTrue(model.supportsVision ?? false)
        XCTAssertTrue(model.supportsTools ?? false)
    }

    func testKeyCreditDecodesAndComputesFraction() throws {
        let json = """
        {"data":{"label":"velachat","usage":3.5,"limit":10.0,"is_free_tier":false}}
        """
        let decoded = try JSONDecoder().decode(
            OpenRouterKeyResponse.self, from: Data(json.utf8)
        )
        let credit = try XCTUnwrap(decoded.data.flatMap {
            $0.usage.map { OpenRouterKeyCredit(usedCredits: $0, limitCredits: $1.limit, label: $1.label) }
        })
        XCTAssertEqual(credit.usedCredits, 3.5)
        XCTAssertEqual(credit.limitCredits, 10.0)
        XCTAssertEqual(credit.label, "velachat")
        XCTAssertEqual(credit.usedFraction, 0.35)
    }

    func testKeyCreditWithoutLimitHasNoFraction() {
        let credit = OpenRouterKeyCredit(usedCredits: 1.25, limitCredits: nil, label: nil)
        XCTAssertNil(credit.usedFraction)
    }
}
