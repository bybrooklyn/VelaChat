import Foundation
import VelaCore
import Observation

/// Per-model characters-per-token ratios, learned from provider-reported
/// `prompt_tokens` and persisted across launches.
///
/// Keyed `"<providerID>|<modelID>"`, the same shape as the context-window
/// overrides and the TTFT samples. Per *provider* as well as per model
/// because the overhead half of the record genuinely is per-endpoint —
/// the same model behind two gateways gets different system scaffolding —
/// and because a ratio learned from a proxy should not be attributed to
/// the vendor's own endpoint.
@MainActor
@Observable
final class TokenCalibrationStore {
    private(set) var records: [String: TokenRatioRecord] = [:]
    private let key = DefaultsKey.tokenRatios

    init() {
        records = Defaults.decode([String: TokenRatioRecord].self, key) ?? [:]
    }

    private func persist() {
        Defaults.encode(records, key)
    }

    /// The ratio to estimate with — the fallback until this model has
    /// `TokenCalibration.minimumSamples` observations.
    func charactersPerToken(for key: String) -> Double {
        TokenCalibration.ratio(from: records[key])
    }

    /// Non-transcript bytes the last request for this model carried, or 0
    /// when nothing has been observed yet. Zero here means "not yet
    /// known", and adds nothing to the estimate — it never pretends to a
    /// number it hasn't seen.
    func overheadUnits(for key: String) -> Int {
        records[key]?.overheadUnits ?? 0
    }

    /// True once this model's estimate is a measurement rather than the
    /// flat fallback — the composer says so rather than leaving the user
    /// to wonder which one they're looking at.
    func isCalibrated(for key: String) -> Bool {
        (records[key]?.samples ?? 0) >= TokenCalibration.minimumSamples
    }

    /// Records one finished reply.
    ///
    /// - Parameters:
    ///   - sentUnits: UTF-8 bytes of everything the request carried —
    ///     system prompt, tool schemas and transcript alike. This must be
    ///     the *whole* request, because `promptTokens` counts the whole
    ///     request.
    ///   - overheadUnits: the part of `sentUnits` that was not transcript.
    ///   - promptTokens: the provider's own count for that request.
    ///
    /// Callers must only pass single-request replies. A reply that ran
    /// tool rounds reports the *sum* of every round's prompt tokens (see
    /// `ToolLoopUsage`), which against one round's text would fit a ratio
    /// several times too small.
    func record(key: String, sentUnits: Int, overheadUnits: Int, promptTokens: Int) {
        guard !key.isEmpty,
              sentUnits > 0,
              promptTokens >= TokenCalibration.minimumSamplePromptTokens else { return }
        let observed = Double(sentUnits) / Double(promptTokens)
        guard var folded = TokenCalibration.folding(records[key], observedRatio: observed) else { return }
        folded.overheadUnits = max(0, overheadUnits)
        records[key] = folded
        persist()
    }

    /// Forgets everything — used by the full-reset path, and by tests.
    func reset() {
        records = [:]
        persist()
    }
}
