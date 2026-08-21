import Foundation

/// The characters-per-token model the context readout runs on, and the
/// arithmetic that fits it to what providers actually report.
///
/// The old estimate was a flat `characters / 4`. That is roughly right for
/// English prose and wrong by 20–50% on source code, and worse again on
/// CJK — always in the unsafe direction, so the ring under-read and the
/// 95% auto-compact trigger fired late or not at all.
///
/// Ground truth is already arriving on every single reply: `prompt_tokens`
/// is provider-reported, and the exact text that produced it is known at
/// send time. Fitting one number per provider+model from those pairs turns
/// the estimate from a constant into a measurement.
public enum TokenCalibration {
    /// Used until a model has enough samples to trust. Unchanged from the
    /// original heuristic on purpose: with no observations, the estimate
    /// must behave exactly as it did before.
    public static let fallbackCharactersPerToken = 4.0

    /// How many observed turns before a fitted ratio replaces the
    /// fallback. Three, because the first sample of a brand-new
    /// conversation is the least representative one there is (a two-word
    /// question against a full system prompt), and because a single
    /// mis-sampled turn should never move the ring on its own. Below this
    /// the samples are still accumulated — just not used.
    public static let minimumSamples = 3

    /// After this many samples the running mean becomes an exponential
    /// moving average, so a model whose usage shifts (prose → code) keeps
    /// tracking instead of freezing on its first ten turns.
    public static let meanSamples = 10

    /// A fitted ratio outside this range is a sign the sample was wrong
    /// (a tool-loop total counted against a single round's text, a
    /// provider that reports cumulative tokens), not a real tokenizer.
    /// Real ratios span ~2 bytes/token for dense CJK to ~5 for whitespace
    /// heavy prose; the bounds are wide enough to keep genuine outliers.
    public static let plausibleRatios = 1.0...12.0

    /// A prompt smaller than this is dominated by whatever the provider
    /// adds on its own (chat template scaffolding, a tool-choice
    /// preamble), so its ratio says more about the provider than the text.
    public static let minimumSamplePromptTokens = 200

    /// The unit everything here counts in: UTF-8 bytes.
    ///
    /// Not `String.count`. The existing transcript estimate already used
    /// `utf8.count`, and bytes are the better base anyway — a tokenizer's
    /// output tracks encoded size far more closely than grapheme count,
    /// which is what made the old constant collapse on CJK.
    public static func units(of text: String) -> Int { text.utf8.count }

    /// Tokens implied by `units` at a given ratio. Never returns 0 for
    /// non-empty input — an empty context and a one-character context are
    /// different things.
    public static func tokens(units: Int, charactersPerToken ratio: Double) -> Int {
        guard units > 0 else { return 0 }
        let safeRatio = plausibleRatios.contains(ratio) ? ratio : fallbackCharactersPerToken
        return max(1, Int((Double(units) / safeRatio).rounded()))
    }

    /// Folds one observation into a stored ratio. Pure arithmetic so the
    /// convergence behaviour is testable without a `UserDefaults` round
    /// trip.
    ///
    /// The first `meanSamples` observations form a true running mean
    /// (weight `1/n`), which converges immediately on a consistent
    /// signal instead of creeping toward it; after that the weight pins at
    /// `1/meanSamples` and it becomes an EMA.
    public static func folding(_ existing: TokenRatioRecord?, observedRatio: Double) -> TokenRatioRecord? {
        guard plausibleRatios.contains(observedRatio) else { return existing }
        guard let existing else {
            return TokenRatioRecord(charactersPerToken: observedRatio, samples: 1)
        }
        let samples = existing.samples + 1
        let weight = 1.0 / Double(min(samples, meanSamples))
        let blended = existing.charactersPerToken * (1 - weight) + observedRatio * weight
        return TokenRatioRecord(charactersPerToken: blended, samples: samples)
    }

    /// The ratio a record supports, or the fallback while it is still
    /// under-sampled.
    public static func ratio(from record: TokenRatioRecord?) -> Double {
        guard let record, record.samples >= minimumSamples,
              plausibleRatios.contains(record.charactersPerToken) else {
            return fallbackCharactersPerToken
        }
        return record.charactersPerToken
    }
}

/// One model's fitted ratio. Two small numbers plus one more — never bytes
/// (see the storage rules in `AGENTS.md`).
public struct TokenRatioRecord: Codable, Equatable, Sendable {
    /// UTF-8 bytes per token, fitted from observed `prompt_tokens`.
    public var charactersPerToken: Double
    /// How many replies have contributed. Gates `TokenCalibration.ratio`.
    public var samples: Int
    /// UTF-8 bytes the last observed request carried that are *not* part
    /// of the transcript: the composed system prompt and the tool schemas.
    ///
    /// The transcript estimate would otherwise be short by exactly this
    /// much on every single turn — a fixed several-thousand-token debt
    /// that the ring never showed and auto-compaction never counted. It is
    /// stored rather than re-derived because the view layer has no access
    /// to the composed prompt, and it is the *last* observation rather
    /// than an average because it changes in steps (a tool toggled off) and
    /// the newest value is always the correct one.
    public var overheadUnits: Int = 0

    public init(charactersPerToken: Double, samples: Int, overheadUnits: Int = 0) {
        self.charactersPerToken = charactersPerToken
        self.samples = samples
        self.overheadUnits = overheadUnits
    }
}

/// What one in-flight reply actually sent, banked at send time so the
/// ratio can be fitted once the provider reports how many tokens that was.
public struct TokenCalibrationSample: Equatable, Sendable {
    /// `"<providerID>|<modelID>"`.
    public let key: String
    /// UTF-8 bytes of the whole request: system prompt, tool schemas and
    /// transcript.
    public let sentUnits: Int
    /// The part of `sentUnits` that wasn't transcript.
    public let overheadUnits: Int

    public init(key: String, sentUnits: Int, overheadUnits: Int) {
        self.key = key
        self.sentUnits = sentUnits
        self.overheadUnits = overheadUnits
    }
}
