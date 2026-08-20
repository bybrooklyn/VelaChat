import XCTest
@testable import VelaChat

/// The context window drives three things at once: the ring, the pre-send
/// cost estimate, and the 95% auto-compact trigger. Before this it came
/// from exactly one source — `contextLength` on a catalog entry — which
/// most providers never publish, so all three were simply dead for most
/// models.
///
/// Table-driven, in the house style of `CostMathTests`: every expectation
/// is a value from a vendor's own documentation or a verbatim error body,
/// not a value read back out of the implementation.
final class ContextWindowTableTests: XCTestCase {

    /// Ids as they really arrive: bare, `vendor/model`, `model:tag`, and
    /// with the dated suffixes providers append.
    func testKnownFamiliesResolve() {
        let cases: [(id: String, expected: Int)] = [
            ("gpt-4o", 128_000),
            ("gpt-4o-mini-2024-07-18", 128_000),
            ("openai/gpt-4o", 128_000),
            ("gpt-4", 8_192),
            ("gpt-4-32k", 32_768),
            ("gpt-4.1", 1_047_576),
            ("gpt-5", 400_000),
            ("gpt-5.6-terra", 1_050_000),
            ("o3-mini", 200_000),
            ("openai/o1-mini", 128_000),
            ("claude-3-5-sonnet-20241022", 200_000),
            ("anthropic/claude-sonnet-4-5", 200_000),
            ("claude-2.1", 100_000),
            ("gemini-1.5-pro", 2_097_152),
            ("gemini-2.0-flash", 1_048_576),
            ("llama-3.1-70b-instruct", 131_072),
            ("llama3.2:3b", 131_072),
            ("llama2:7b", 4_096),
            ("mistral-large-2411", 131_072),
            ("mixtral:8x7b", 32_768),
            ("deepseek-v4-flash", 1_000_000),
            ("deepseek-reasoner", 65_536),
            ("qwen3:30b", 32_768),
            ("gpt-oss:20b", 131_072),
            ("grok-4", 256_000),
            ("command-r-plus", 128_000),
        ]
        for (id, expected) in cases {
            XCTAssertEqual(ContextWindowTable.contextLength(for: id), expected, "id: \(id)")
        }
    }

    /// A wrong number is worse than no number — the ring presents whatever
    /// it gets as the truth — so anything unrecognized must stay `nil` and
    /// fall through to the manual override in the composer.
    func testUnknownIdsReturnNil() {
        let unknown = [
            "",
            "local-model",
            "my-finetune-v7",
            "some-internal/proxy-model",
            "text-embedding-3-large",
            "nomic-embed-text",
            "whisper-1",
        ]
        for id in unknown {
            XCTAssertNil(ContextWindowTable.contextLength(for: id), "id: \(id)")
        }
    }

    /// The short OpenAI reasoning ids (`o1`, `o3`) are anchored to the
    /// start of the id's leaf precisely so they can't match the middle of
    /// an unrelated one. Without that anchoring these would all resolve to
    /// 200k.
    func testShortReasoningIdsDoNotMatchSubstrings() {
        XCTAssertNil(ContextWindowTable.contextLength(for: "acme-o3-turbo"))
        XCTAssertNil(ContextWindowTable.contextLength(for: "hermes-o1"))
        XCTAssertEqual(ContextWindowTable.contextLength(for: "o3"), 200_000)
        XCTAssertEqual(ContextWindowTable.contextLength(for: "openai/o3-mini-high"), 200_000)
    }

    /// Order is load-bearing: a general pattern listed before a specific
    /// one silently shadows it. These pairs are the ones that would break
    /// first if entries were ever re-sorted alphabetically.
    func testSpecificPatternsWinOverGeneralOnes() {
        XCTAssertEqual(ContextWindowTable.contextLength(for: "gpt-4o"), 128_000, "must not fall through to gpt-4's 8192")
        XCTAssertEqual(ContextWindowTable.contextLength(for: "gpt-4.1-mini"), 1_047_576, "must not fall through to gpt-4's 8192")
        XCTAssertEqual(ContextWindowTable.contextLength(for: "llama-3.1-8b"), 131_072, "must not fall through to llama-3's 8192")
        XCTAssertEqual(ContextWindowTable.contextLength(for: "mistral-large"), 131_072, "must not fall through to mistral's 32768")
        XCTAssertEqual(ContextWindowTable.contextLength(for: "deepseek-v4-pro"), 1_000_000, "must not fall through to deepseek-v3's 65536")
    }
}

final class ContextWindowResolverTests: XCTestCase {

    /// The stated rule: the table is a fallback, never an override.
    func testCatalogBeatsCuratedTable() {
        // The table would say 128,000 for a gpt-4o id.
        let resolved = ContextWindowResolver.resolve(
            manual: nil, learned: nil, catalog: 64_000, modelID: "gpt-4o"
        )
        XCTAssertEqual(resolved, ContextWindowResolver.Resolved(value: 64_000, source: .catalog))
    }

    /// Observed beats published: the error came from the deployment being
    /// called, the catalog describes a model in the abstract.
    func testLearnedBeatsCatalogAndTable() {
        let resolved = ContextWindowResolver.resolve(
            manual: nil, learned: 32_768, catalog: 200_000, modelID: "claude-3-5-sonnet"
        )
        XCTAssertEqual(resolved, ContextWindowResolver.Resolved(value: 32_768, source: .learned))
    }

    /// A human's explicit correction outranks everything automatic — the
    /// whole reason learned values live in their own store.
    func testManualBeatsEverything() {
        let resolved = ContextWindowResolver.resolve(
            manual: 16_000, learned: 32_768, catalog: 200_000, modelID: "claude-3-5-sonnet"
        )
        XCTAssertEqual(resolved, ContextWindowResolver.Resolved(value: 16_000, source: .manual))
    }

    func testCuratedTableIsTheLastResort() {
        let resolved = ContextWindowResolver.resolve(
            manual: nil, learned: nil, catalog: nil, modelID: "llama-3.1-70b"
        )
        XCTAssertEqual(resolved, ContextWindowResolver.Resolved(value: 131_072, source: .curated))
        XCTAssertFalse(ContextWindowSource.curated.isObserved)
    }

    func testNothingKnownStaysNil() {
        XCTAssertNil(ContextWindowResolver.resolve(
            manual: nil, learned: nil, catalog: nil, modelID: "my-finetune-v7"
        ))
    }

    /// Zero is not a window. A stored 0 (a cleared override written as 0, a
    /// catalog that publishes `"context_length": 0`) must not win and must
    /// not divide anything.
    func testNonPositiveValuesAreIgnored() {
        let resolved = ContextWindowResolver.resolve(
            manual: 0, learned: 0, catalog: 128_000, modelID: "gpt-4o"
        )
        XCTAssertEqual(resolved, ContextWindowResolver.Resolved(value: 128_000, source: .catalog))
    }
}

final class ContextWindowLearningTests: XCTestCase {

    /// Verbatim-shaped bodies from the providers this app talks to. This is
    /// the only *observed* source of a context window in the whole app, so
    /// the patterns have to survive real punctuation and real prefixes —
    /// including `APIError.status`'s "Request failed (400)." wrapper, which
    /// is what actually reaches the learning hook.
    func testParsesRealProviderErrors() {
        let cases: [(text: String, expected: Int)] = [
            (
                "This model's maximum context length is 8192 tokens. However, you requested 9134 tokens (8622 in the messages, 512 in the completion). Please reduce the length of the messages or completion.",
                8_192
            ),
            (
                "Request failed (400). This model's maximum context length is 128000 tokens. However, your messages resulted in 131500 tokens.",
                128_000
            ),
            (
                "Error code: 400 - {'error': {'message': \"This model's maximum context length is 16385 tokens.\", 'type': 'invalid_request_error'}}",
                16_385
            ),
            (
                "input length and `max_tokens` exceed context limit: 195000 + 8192 > 200000, decrease input length or `max_tokens` and try again",
                200_000
            ),
            (
                "The input exceeds the model's context window of 32768 tokens.",
                32_768
            ),
            (
                "the request exceeds the model's context window (4096) — try increasing the context size",
                4_096
            ),
            (
                "MAXIMUM CONTEXT LENGTH IS 200000 TOKENS",
                200_000
            ),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(
                ContextWindowLearning.contextLength(fromErrorText: text),
                expected,
                "text: \(text.prefix(60))…"
            )
        }
    }

    /// The dangerous false positive. An *output* cap is not a context
    /// window: recording 8,192 as the window of a 200k model would make
    /// the ring lie and auto-compaction thrash on every turn.
    func testIgnoresOutputCapsAndUnrelatedErrors() {
        let ignored = [
            "",
            "max_tokens: 8192 > 4096, which is the maximum number of output tokens for this model",
            "Rate limit exceeded. Limit 30000 tokens per minute.",
            "Request failed (401). Incorrect API key provided.",
            "You requested 9134 tokens, which is too many.",
            "Insufficient quota: you have used 128000 of your 100000 monthly tokens.",
            "The response stream could not be parsed.",
            "Request failed (500). upstream connect error or disconnect/reset before headers",
        ]
        for text in ignored {
            XCTAssertNil(
                ContextWindowLearning.contextLength(fromErrorText: text),
                "text: \(text.prefix(60))…"
            )
        }
    }

    /// A number outside the plausible range is a misparse, not a window.
    func testImplausibleNumbersAreRejected() {
        XCTAssertNil(ContextWindowLearning.contextLength(fromErrorText: "maximum context length is 12 tokens"))
        XCTAssertNil(ContextWindowLearning.contextLength(fromErrorText: "maximum context length is 99999999999 tokens"))
    }

    /// Providers vary on thousands separators; the number is the number.
    func testToleratesSeparators() {
        XCTAssertEqual(
            ContextWindowLearning.contextLength(fromErrorText: "This model's maximum context length is 128,000 tokens."),
            128_000
        )
    }
}
