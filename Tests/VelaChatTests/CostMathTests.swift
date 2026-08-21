import XCTest
@testable import VelaChat
@testable import VelaCore

/// Table-driven cost math. The formula this replaces captured
/// `cachedTokens` off the wire and then never used it, which was wrong in
/// opposite directions per provider — undercounting Anthropic (cache reads
/// and writes billed as nothing) and overcounting OpenAI-compatible
/// providers (cached tokens billed at full input price).
///
/// Every expected value here is computed by hand from the published
/// multipliers, not from the implementation.
final class CostMathTests: XCTestCase {

    /// $3/M input, $15/M output — round numbers so the arithmetic in each
    /// expectation stays checkable by eye.
    private let model = RemoteModel(id: "test-model", inputPricePerMillion: 3.0, outputPricePerMillion: 15.0)

    private func summary(
        prompt: Int? = nil,
        completion: Int? = nil,
        cached: Int? = nil,
        write5m: Int? = nil,
        write1h: Int? = nil,
        batch: Bool = false,
        providerCost: Double? = nil
    ) -> UsageSummary {
        var value = UsageSummary(promptTokens: prompt, completionTokens: completion, cachedTokens: cached)
        value.cacheCreation5mTokens = write5m
        value.cacheCreation1hTokens = write1h
        value.isBatch = batch
        value.providerReportedCostUSD = providerCost
        return value
    }

    private func assertCost(
        _ actual: Double?,
        _ expected: Double,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected a cost, got nil. \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-9, message, file: file, line: line)
    }

    // MARK: No cache

    func testNoCache() {
        // 1,000,000 × $3 + 1,000,000 × $15 = $18
        let cost = summary(prompt: 1_000_000, completion: 1_000_000)
            .costUSD(for: model, promptIncludesCached: true)
        assertCost(cost, 18.0)
    }

    func testNoCacheSmallNumbers() {
        // 10,000 input + 2,000 output = 0.03 + 0.03 = $0.06
        let cost = summary(prompt: 10_000, completion: 2_000)
            .costUSD(for: model, promptIncludesCached: false)
        assertCost(cost, 0.06)
    }

    // MARK: Cache reads

    /// OpenAI-compatible: `prompt_tokens` INCLUDES the cached portion, so
    /// the cached tokens must be subtracted before pricing fresh input,
    /// then re-priced at 0.10x. Previously they were billed at full rate.
    func testCacheReadsWhenPromptIncludesCached() {
        // prompt 100k of which 80k cached → 20k fresh.
        // 20,000 × 3 + 80,000 × 3 × 0.10 + 1,000 × 15
        //   = 0.06 + 0.024 + 0.015 = $0.099
        let cost = summary(prompt: 100_000, completion: 1_000, cached: 80_000)
            .costUSD(for: model, promptIncludesCached: true)
        assertCost(cost, 0.099)
    }

    /// Anthropic: `input_tokens` EXCLUDES cached tokens, so the full
    /// prompt count is already fresh input and nothing is subtracted.
    func testCacheReadsWhenPromptExcludesCached() {
        // 20,000 × 3 + 80,000 × 3 × 0.10 + 1,000 × 15
        //   = 0.06 + 0.024 + 0.015 = $0.099
        let cost = summary(prompt: 20_000, completion: 1_000, cached: 80_000)
            .costUSD(for: model, promptIncludesCached: false)
        assertCost(cost, 0.099)
    }

    /// The same physical request under both conventions must cost the
    /// same. This is the whole point of the per-provider capability.
    func testTheTwoConventionsAgreeOnTheSameRequest() throws {
        let openAIStyle = summary(prompt: 100_000, completion: 1_000, cached: 80_000)
            .costUSD(for: model, promptIncludesCached: true)
        let anthropicStyle = summary(prompt: 20_000, completion: 1_000, cached: 80_000)
            .costUSD(for: model, promptIncludesCached: false)
        XCTAssertEqual(try XCTUnwrap(openAIStyle), try XCTUnwrap(anthropicStyle), accuracy: 1e-12)
    }

    /// The old formula's overcount, pinned so a regression is visible:
    /// billing 80k cached tokens at full rate instead of 0.10x.
    func testCachedTokensAreNotBilledAtFullInputRate() throws {
        let cost = try? XCTUnwrap(
            summary(prompt: 100_000, completion: 1_000, cached: 80_000)
                .costUSD(for: model, promptIncludesCached: true)
        )
        let naive = (100_000.0 * 3.0 + 1_000.0 * 15.0) / 1_000_000  // = $0.315
        XCTAssertLessThan(try XCTUnwrap(cost), naive)
    }

    // MARK: Cache writes

    func testFiveMinuteWritesBillAt125Percent() {
        // 10,000 × 3 × 1.25 = $0.0375
        let cost = summary(prompt: 0, completion: 0, write5m: 10_000)
            .costUSD(for: model, promptIncludesCached: false)
        assertCost(cost, 0.0375)
    }

    func testOneHourWritesBillAtDouble() {
        // 10,000 × 3 × 2.0 = $0.06
        let cost = summary(prompt: 0, completion: 0, write1h: 10_000)
            .costUSD(for: model, promptIncludesCached: false)
        assertCost(cost, 0.06)
    }

    /// Collapsing the two tiers into one number would misprice by 60%.
    func testTheTwoWriteTiersArePricedDifferently() throws {
        // prompt/completion must be present: a cost is only computed when
        // both token counts were actually reported.
        let fiveMinute = summary(prompt: 0, completion: 0, write5m: 10_000)
            .costUSD(for: model, promptIncludesCached: false)
        let oneHour = summary(prompt: 0, completion: 0, write1h: 10_000)
            .costUSD(for: model, promptIncludesCached: false)
        XCTAssertNotEqual(try XCTUnwrap(fiveMinute), try XCTUnwrap(oneHour))
    }

    /// Writes were previously unpriced entirely — the Anthropic undercount.
    func testWritesAreNotFree() throws {
        let cost = summary(prompt: 1_000, completion: 100, write1h: 50_000)
            .costUSD(for: model, promptIncludesCached: false)
        let withoutWrites = summary(prompt: 1_000, completion: 100)
            .costUSD(for: model, promptIncludesCached: false)
        XCTAssertGreaterThan(try XCTUnwrap(cost), try XCTUnwrap(withoutWrites))
    }

    // MARK: Mixed

    func testMixedReadsAndBothWriteTiers() {
        // fresh 5,000 × 3                 = 0.015
        // output 2,000 × 15               = 0.030
        // 5m write 4,000 × 3 × 1.25       = 0.015
        // 1h write 2,000 × 3 × 2.0        = 0.012
        // reads   50,000 × 3 × 0.10       = 0.015
        //                                 = $0.087
        let cost = summary(prompt: 5_000, completion: 2_000, cached: 50_000, write5m: 4_000, write1h: 2_000)
            .costUSD(for: model, promptIncludesCached: false)
        assertCost(cost, 0.087)
    }

    // MARK: Batch

    func testBatchHalvesEverything() throws {
        let normal = try? XCTUnwrap(
            summary(prompt: 5_000, completion: 2_000, cached: 50_000, write5m: 4_000, write1h: 2_000)
                .costUSD(for: model, promptIncludesCached: false)
        )
        let batched = summary(prompt: 5_000, completion: 2_000, cached: 50_000, write5m: 4_000, write1h: 2_000, batch: true)
            .costUSD(for: model, promptIncludesCached: false)
        assertCost(batched, try XCTUnwrap(normal) * 0.5)
        assertCost(batched, 0.0435)
    }

    // MARK: Provider-reported cost

    /// An observed number always beats a derived one.
    func testProviderReportedCostWins() {
        let value = summary(prompt: 999_999, completion: 999_999, providerCost: 0.4242)
        assertCost(value.costUSD(for: model, promptIncludesCached: true), 0.4242)
        XCTAssertTrue(value.isCostProviderReported)
    }

    func testProviderReportedCostWorksWithoutPricing() {
        // No model pricing at all, but the provider told us the cost.
        let value = summary(prompt: 10, completion: 10, providerCost: 0.5)
        assertCost(value.costUSD(for: nil, promptIncludesCached: true), 0.5)
    }

    // MARK: Unknown stays unknown

    func testNilWhenPricingUnknown() {
        let unpriced = RemoteModel(id: "local-model")
        XCTAssertNil(summary(prompt: 100, completion: 100).costUSD(for: unpriced, promptIncludesCached: true))
        XCTAssertNil(summary(prompt: 100, completion: 100).costUSD(for: nil, promptIncludesCached: true))
    }

    func testNilWhenTokenCountsMissing() {
        XCTAssertNil(summary(completion: 100).costUSD(for: model, promptIncludesCached: true))
        XCTAssertNil(summary(prompt: 100).costUSD(for: model, promptIncludesCached: true))
    }

    /// `nil` and `0` must stay distinct: "not reported" is not "none".
    func testUnreportedCacheIsNotTreatedAsZeroInTheModel() {
        XCTAssertNil(summary(prompt: 1, completion: 1).cacheCreationTokens)
        XCTAssertEqual(summary(prompt: 1, completion: 1, write5m: 0).cacheCreationTokens, 0)
    }

    /// Subtracting cached from prompt must never go negative, even if a
    /// provider reports something inconsistent.
    func testCachedExceedingPromptDoesNotProduceNegativeInput() {
        let cost = summary(prompt: 100, completion: 0, cached: 5_000)
            .costUSD(for: model, promptIncludesCached: true)
        // Fresh input floors at 0; only the cache read is billed.
        assertCost(cost, 5_000.0 * 3.0 * 0.10 / 1_000_000)
    }

    // MARK: The provider capability itself

    func testProviderKindCapability() {
        // Anthropic excludes cached tokens from input_tokens.
        XCTAssertFalse(ProviderKind.anthropic.promptTokensIncludeCached)
        // OpenAI-style providers include them in prompt_tokens.
        XCTAssertTrue(ProviderKind.openAI.promptTokensIncludeCached)
        XCTAssertTrue(ProviderKind.deepSeek.promptTokensIncludeCached)
        XCTAssertTrue(ProviderKind.openRouter.promptTokensIncludeCached)
    }
}
