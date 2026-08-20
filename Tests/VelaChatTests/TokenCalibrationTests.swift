import XCTest
@testable import VelaChat

/// The context readout used to divide characters by a flat 4. That's
/// roughly right for English prose and wrong by 20–50% on code — always in
/// the unsafe direction, so the ring under-read and the 95% auto-compact
/// trigger fired late or never.
///
/// Ground truth arrives on every reply: `prompt_tokens` is
/// provider-reported. These tests pin the two properties that matter — it
/// behaves exactly like the old constant until it has evidence, and it
/// converges on the evidence once it has it.
final class TokenCalibrationTests: XCTestCase {

    // MARK: Fallback

    func testFallbackWithNoSamples() {
        XCTAssertEqual(TokenCalibration.ratio(from: nil), 4.0)
    }

    /// Samples below the trust threshold accumulate but must not move the
    /// estimate: the first turn of a conversation is the least
    /// representative sample there is.
    func testUnderSampledRecordStillUsesFallback() {
        var record: TokenRatioRecord?
        for _ in 0..<(TokenCalibration.minimumSamples - 1) {
            record = TokenCalibration.folding(record, observedRatio: 2.5)
        }
        XCTAssertEqual(record?.samples, TokenCalibration.minimumSamples - 1)
        XCTAssertEqual(TokenCalibration.ratio(from: record), 4.0, "still under-sampled")

        record = TokenCalibration.folding(record, observedRatio: 2.5)
        XCTAssertEqual(TokenCalibration.ratio(from: record), 2.5, accuracy: 1e-9, "threshold reached")
    }

    /// With no samples the estimate must reproduce the old behaviour
    /// exactly — 4,000 bytes of ASCII reads as 1,000 tokens.
    func testFallbackEstimateMatchesTheOldConstant() {
        let text = String(repeating: "a", count: 4_000)
        XCTAssertEqual(
            TokenCalibration.tokens(units: TokenCalibration.units(of: text), charactersPerToken: 4.0),
            1_000
        )
    }

    // MARK: Convergence

    /// A model that consistently reports 3.2 bytes/token — dense source
    /// code — must be estimated at 3.2, not 4.0. Under the old constant
    /// that content was under-counted by 25%.
    func testConvergesOnAConsistentSignal() {
        var record: TokenRatioRecord?
        for _ in 0..<8 {
            record = TokenCalibration.folding(record, observedRatio: 3.2)
        }
        XCTAssertEqual(TokenCalibration.ratio(from: record), 3.2, accuracy: 1e-9)
    }

    /// Fed real (bytes, prompt_tokens) pairs, the fitted ratio must
    /// reproduce the provider's own count. This is the whole contract:
    /// estimate(sent bytes) ≈ what the provider charged.
    func testFittedRatioReproducesReportedPromptTokens() {
        let sentUnits = 48_000
        let reportedPromptTokens = 15_000   // 3.2 bytes/token

        var record: TokenRatioRecord?
        for _ in 0..<5 {
            record = TokenCalibration.folding(
                record,
                observedRatio: Double(sentUnits) / Double(reportedPromptTokens)
            )
        }
        let estimate = TokenCalibration.tokens(
            units: sentUnits,
            charactersPerToken: TokenCalibration.ratio(from: record)
        )
        XCTAssertEqual(estimate, reportedPromptTokens)
    }

    /// A model whose content shifts (prose → code) has to keep tracking.
    /// The running mean converges quickly, then the EMA keeps moving.
    func testTracksAShiftingSignal() {
        var record: TokenRatioRecord?
        for _ in 0..<10 { record = TokenCalibration.folding(record, observedRatio: 4.5) }
        XCTAssertEqual(TokenCalibration.ratio(from: record), 4.5, accuracy: 1e-9)

        for _ in 0..<40 { record = TokenCalibration.folding(record, observedRatio: 2.8) }
        XCTAssertEqual(TokenCalibration.ratio(from: record), 2.8, accuracy: 0.05, "should have followed the new signal")
    }

    // MARK: Guards

    /// A ratio outside the plausible band means the sample was wrong — a
    /// tool loop's summed `prompt_tokens` measured against one round's
    /// text, say. Such a sample must be discarded, not averaged in.
    func testImplausibleObservationsAreDiscarded() {
        var record: TokenRatioRecord?
        for _ in 0..<5 { record = TokenCalibration.folding(record, observedRatio: 3.5) }
        let before = record

        record = TokenCalibration.folding(record, observedRatio: 0.2)    // summed tool-loop tokens
        record = TokenCalibration.folding(record, observedRatio: 900.0)  // a provider reporting nonsense
        XCTAssertEqual(record, before, "an implausible sample must not move the fit")
    }

    /// A stored ratio that somehow ends up out of range must not be used
    /// to divide by — the estimate falls back rather than reporting a
    /// number a thousand times wrong.
    func testCorruptStoredRatioFallsBack() {
        let corrupt = TokenRatioRecord(charactersPerToken: 0.0001, samples: 50)
        XCTAssertEqual(TokenCalibration.ratio(from: corrupt), 4.0)
        XCTAssertEqual(TokenCalibration.tokens(units: 4_000, charactersPerToken: 0.0001), 1_000)
    }

    /// `nil` and `0` are different things everywhere else in this app, and
    /// they are here too: no text is zero tokens, one byte is not.
    func testEmptyIsZeroAndOneByteIsNotZero() {
        XCTAssertEqual(TokenCalibration.tokens(units: 0, charactersPerToken: 4.0), 0)
        XCTAssertEqual(TokenCalibration.tokens(units: 1, charactersPerToken: 4.0), 1)
    }

    /// Bytes, not graphemes. Three ASCII characters are three units; three
    /// CJK characters are nine — which is exactly why the old
    /// grapheme-flavoured constant collapsed on CJK text.
    func testUnitsAreUTF8Bytes() {
        XCTAssertEqual(TokenCalibration.units(of: "abc"), 3)
        XCTAssertEqual(TokenCalibration.units(of: "日本語"), 9)
        XCTAssertEqual(TokenCalibration.units(of: ""), 0)
    }
}

/// The persisted half. Deliberately thin — the arithmetic is covered
/// above; what's left to prove is the gate, the guards, and that the
/// stored shape survives a round trip.
@MainActor
final class TokenCalibrationStoreTests: XCTestCase {
    private let key = "test-provider|test-model"

    private func freshStore() -> TokenCalibrationStore {
        let store = TokenCalibrationStore()
        store.reset()
        return store
    }

    override func tearDown() async throws {
        TokenCalibrationStore().reset()
        try await super.tearDown()
    }

    func testUnknownModelUsesTheFallback() {
        let store = freshStore()
        XCTAssertEqual(store.charactersPerToken(for: key), 4.0)
        XCTAssertEqual(store.overheadUnits(for: key), 0, "unknown overhead adds nothing, rather than being guessed")
        XCTAssertFalse(store.isCalibrated(for: key))
    }

    func testRecordingConvergesOnTheProvidersCount() {
        let store = freshStore()
        for _ in 0..<TokenCalibration.minimumSamples {
            store.record(key: key, sentUnits: 32_000, overheadUnits: 6_000, promptTokens: 10_000)
        }
        XCTAssertTrue(store.isCalibrated(for: key))
        XCTAssertEqual(store.charactersPerToken(for: key), 3.2, accuracy: 1e-9)
        XCTAssertEqual(store.overheadUnits(for: key), 6_000)
    }

    /// A prompt too small to be representative is dominated by whatever
    /// scaffolding the provider adds on its own.
    func testTinyPromptsAreNotSampled() {
        let store = freshStore()
        for _ in 0..<10 {
            store.record(key: key, sentUnits: 40, overheadUnits: 0, promptTokens: 10)
        }
        XCTAssertFalse(store.isCalibrated(for: key))
        XCTAssertEqual(store.charactersPerToken(for: key), 4.0)
    }

    func testMalformedSamplesAreIgnored() {
        let store = freshStore()
        store.record(key: "", sentUnits: 32_000, overheadUnits: 0, promptTokens: 10_000)
        store.record(key: key, sentUnits: 0, overheadUnits: 0, promptTokens: 10_000)
        XCTAssertTrue(store.records.isEmpty)
    }

    /// Overhead is the newest observation, not an average: it changes in
    /// steps when a tool is toggled, and the newest value is the correct
    /// one.
    func testOverheadTracksTheLatestObservation() {
        let store = freshStore()
        store.record(key: key, sentUnits: 32_000, overheadUnits: 6_000, promptTokens: 10_000)
        store.record(key: key, sentUnits: 32_000, overheadUnits: 1_200, promptTokens: 10_000)
        XCTAssertEqual(store.overheadUnits(for: key), 1_200)
    }
}
