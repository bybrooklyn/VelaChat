import Foundation

/// Where a context-window figure came from. The UI shows this so a
/// fallback number never reads as something the provider actually
/// published (house rule: unobserved numbers are never implied).
enum ContextWindowSource: String, Codable, Sendable {
    /// The user typed it into the context popover.
    case manual
    /// Parsed out of the endpoint's own error text — the only *observed*
    /// source, and the only one that can know a proxy's or self-hosted
    /// server's real limit.
    case learned
    /// The provider's `/models` response published it.
    case catalog
    /// `ContextWindowTable` — a well-known-family fallback. A guess.
    case curated

    /// Short provenance label for the context popover.
    var label: String {
        switch self {
        case .manual: "manually set"
        case .learned: "learned from this endpoint"
        case .catalog: "published by the provider"
        case .curated: "typical for this model family"
        }
    }

    /// True when the number was actually reported by something rather than
    /// assumed from a model's name.
    var isObserved: Bool { self != .curated }
}

/// Resolves the one context-window number the ring, the pre-send estimate
/// and auto-compaction all read, from the four possible sources.
///
/// **Precedence — manual > learned > catalog > curated.** The obvious
/// alternative (catalog first, because it's the vendor's own metadata) is
/// wrong here:
///
/// - A **manual** value is an explicit human decision about *this*
///   endpoint, made while looking at the ring and at whatever the endpoint
///   has been doing. Nothing automatic may silently overwrite or outrank
///   it — that would be exactly the invisible magic this app avoids. The
///   user can always clear it and fall back to auto-detection.
/// - A **learned** value beats the **catalog** because the catalog
///   describes a model in the abstract while the error came back from the
///   deployment actually being called. A gateway in front of Claude can
///   cap far below 200k; a self-hosted `num_ctx` bears no relation to what
///   the upstream model supports. Observed beats published.
/// - The **curated table** ranks last precisely because it is the only
///   source that never observed anything.
///
/// Learned values are stored separately from manual overrides rather than
/// written into them, so this ordering stays expressible and so a user's
/// correction survives whatever the endpoint says next.
enum ContextWindowResolver {
    struct Resolved: Equatable {
        let value: Int
        let source: ContextWindowSource
    }

    static func resolve(manual: Int?, learned: Int?, catalog: Int?, modelID: String) -> Resolved? {
        if let manual, manual > 0 { return Resolved(value: manual, source: .manual) }
        if let learned, learned > 0 { return Resolved(value: learned, source: .learned) }
        if let catalog, catalog > 0 { return Resolved(value: catalog, source: .catalog) }
        if let curated = ContextWindowTable.contextLength(for: modelID) {
            return Resolved(value: curated, source: .curated)
        }
        return nil
    }
}

/// Model-id pattern → context window, for families whose limits are
/// published and stable.
///
/// This exists because most `/v1/models` responses carry no context length
/// at all: OpenAI's doesn't, Anthropic's doesn't, DeepSeek's doesn't,
/// Groq's and Mistral's don't. Without a window the ring shows nothing and
/// the auto-compact safety net can never fire, which is strictly worse
/// than a documented figure for a recognizable model.
///
/// Rules this table follows:
/// - It is a **fallback, never an override**. A catalog-published value
///   always wins (see `ContextWindowResolver`), because a provider that
///   bothered to publish one knows its own deployment.
/// - Values are the vendors' documented **API** context windows, not
///   marketing maxima and not beta opt-ins (Claude's 1M-token window needs
///   an explicit beta header this app does not send, so Claude stays at
///   200k here).
/// - Matching is **first-match-wins over an ordered list**, so more
///   specific ids must be listed before the families that contain them
///   (`gpt-4o` before `gpt-4`, `deepseek-v4` before `deepseek-v3`). Order
///   is load-bearing; adding an entry in the wrong place silently shadows
///   it.
/// - Anything not recognized returns `nil`. A wrong number is worse than
///   no number, because the ring presents whatever it gets as the truth.
enum ContextWindowTable {
    /// How an entry's pattern is compared against a model id.
    enum Match {
        /// Anywhere in the lowercased id. The default: it survives the
        /// `vendor/model:tag` and `-2025-01-31` decorations providers add.
        case contains
        /// Only at the start of the id's last path component. Reserved for
        /// ids short enough to appear inside unrelated ones — `o1` and
        /// `o3` would otherwise match any id containing those two
        /// characters in sequence.
        case leafPrefix
    }

    struct Entry {
        let pattern: String
        let contextLength: Int
        var match: Match = .contains
    }

    /// Ordered most-specific-first; the first match wins.
    static let entries: [Entry] = [
        // OpenAI — GPT-5 family
        Entry(pattern: "gpt-5.6", contextLength: 1_050_000),
        Entry(pattern: "gpt-5", contextLength: 400_000),
        // OpenAI — reasoning models. Short ids, so anchored to the leaf.
        Entry(pattern: "o4-mini", contextLength: 200_000, match: .leafPrefix),
        Entry(pattern: "o3-mini", contextLength: 200_000, match: .leafPrefix),
        Entry(pattern: "o3", contextLength: 200_000, match: .leafPrefix),
        Entry(pattern: "o1-mini", contextLength: 128_000, match: .leafPrefix),
        Entry(pattern: "o1", contextLength: 200_000, match: .leafPrefix),
        // OpenAI — GPT-4 family (specific before general)
        Entry(pattern: "gpt-4.1", contextLength: 1_047_576),
        Entry(pattern: "gpt-4o", contextLength: 128_000),
        Entry(pattern: "gpt-4-turbo", contextLength: 128_000),
        Entry(pattern: "gpt-4-32k", contextLength: 32_768),
        Entry(pattern: "gpt-4", contextLength: 8_192),
        Entry(pattern: "gpt-3.5-turbo-16k", contextLength: 16_385),
        Entry(pattern: "gpt-3.5", contextLength: 16_385),
        // OpenAI open-weight
        Entry(pattern: "gpt-oss", contextLength: 131_072),
        // Anthropic
        Entry(pattern: "claude-3", contextLength: 200_000),
        Entry(pattern: "claude-sonnet-4", contextLength: 200_000),
        Entry(pattern: "claude-opus-4", contextLength: 200_000),
        Entry(pattern: "claude-haiku-4", contextLength: 200_000),
        Entry(pattern: "claude-4", contextLength: 200_000),
        Entry(pattern: "claude-2", contextLength: 100_000),
        Entry(pattern: "claude-instant", contextLength: 100_000),
        Entry(pattern: "claude", contextLength: 200_000),
        // Google
        Entry(pattern: "gemini-1.5-pro", contextLength: 2_097_152),
        Entry(pattern: "gemini-1.5", contextLength: 1_048_576),
        Entry(pattern: "gemini-2", contextLength: 1_048_576),
        Entry(pattern: "gemini-3", contextLength: 1_048_576),
        Entry(pattern: "gemini", contextLength: 1_048_576),
        Entry(pattern: "gemma-3", contextLength: 128_000),
        Entry(pattern: "gemma3", contextLength: 128_000),
        Entry(pattern: "gemma-2", contextLength: 8_192),
        Entry(pattern: "gemma2", contextLength: 8_192),
        // Meta
        Entry(pattern: "llama-4", contextLength: 1_048_576),
        Entry(pattern: "llama4", contextLength: 1_048_576),
        Entry(pattern: "llama-3.1", contextLength: 131_072),
        Entry(pattern: "llama3.1", contextLength: 131_072),
        Entry(pattern: "llama-3.2", contextLength: 131_072),
        Entry(pattern: "llama3.2", contextLength: 131_072),
        Entry(pattern: "llama-3.3", contextLength: 131_072),
        Entry(pattern: "llama3.3", contextLength: 131_072),
        Entry(pattern: "llama-3", contextLength: 8_192),
        Entry(pattern: "llama3", contextLength: 8_192),
        Entry(pattern: "llama-2", contextLength: 4_096),
        Entry(pattern: "llama2", contextLength: 4_096),
        // Mistral
        Entry(pattern: "mistral-large", contextLength: 131_072),
        Entry(pattern: "mistral-small", contextLength: 32_768),
        Entry(pattern: "mistral-nemo", contextLength: 131_072),
        Entry(pattern: "ministral", contextLength: 131_072),
        Entry(pattern: "codestral", contextLength: 32_768),
        Entry(pattern: "mixtral", contextLength: 32_768),
        Entry(pattern: "pixtral", contextLength: 131_072),
        Entry(pattern: "mistral", contextLength: 32_768),
        // DeepSeek
        Entry(pattern: "deepseek-v4", contextLength: 1_000_000),
        Entry(pattern: "deepseek-v3", contextLength: 65_536),
        Entry(pattern: "deepseek-r1", contextLength: 65_536),
        Entry(pattern: "deepseek-reasoner", contextLength: 65_536),
        Entry(pattern: "deepseek-chat", contextLength: 65_536),
        Entry(pattern: "deepseek-coder", contextLength: 65_536),
        // Qwen
        Entry(pattern: "qwen3", contextLength: 32_768),
        Entry(pattern: "qwen-3", contextLength: 32_768),
        Entry(pattern: "qwen2.5", contextLength: 32_768),
        Entry(pattern: "qwen2", contextLength: 32_768),
        // xAI
        Entry(pattern: "grok-4", contextLength: 256_000),
        Entry(pattern: "grok-3", contextLength: 131_072),
        Entry(pattern: "grok-2", contextLength: 131_072),
        // Cohere
        Entry(pattern: "command-r-plus", contextLength: 128_000),
        Entry(pattern: "command-r", contextLength: 128_000),
        // Microsoft
        Entry(pattern: "phi-4", contextLength: 16_384),
    ]

    /// The window for a model id, or `nil` when this table has no
    /// documented figure for it. Case-insensitive, and tolerant of the
    /// `vendor/model:tag` shapes OpenRouter and Ollama use.
    static func contextLength(for modelID: String) -> Int? {
        let lower = modelID.lowercased()
        guard !lower.isEmpty else { return nil }
        let leaf = lower.split(separator: "/").last.map(String.init) ?? lower
        for entry in entries {
            switch entry.match {
            case .contains where lower.contains(entry.pattern):
                return entry.contextLength
            case .leafPrefix where leaf.hasPrefix(entry.pattern):
                return entry.contextLength
            default:
                continue
            }
        }
        return nil
    }
}

/// Reads a real context window out of a provider's error text.
///
/// This is the only source in the app that *observes* an endpoint's actual
/// limit rather than looking it up. It matters most exactly where lookup
/// fails: a self-hosted llama.cpp started with `-c 8192`, a corporate
/// gateway capping a 200k model at 32k, an OpenRouter route whose upstream
/// is smaller than the catalog claims. The endpoint states the number in
/// the 400 it returns; before this it was thrown away with the rest of the
/// error string.
enum ContextWindowLearning {
    /// Below this a "context window" is almost certainly a misparse (a
    /// message count, an HTTP status); above it, a fantasy.
    static let plausibleRange = 512...20_000_000

    /// Ordered regexes, each with exactly one capture group holding the
    /// window. Written against error bodies these providers really emit —
    /// see `ContextWindowLearningTests` for the verbatim variants.
    private static let patterns: [NSRegularExpression] = [
        // OpenAI / vLLM / Together / most compatible servers:
        // "This model's maximum context length is 8192 tokens."
        #"maximum context (?:length|window|size)\s+(?:is|of)\s+([0-9][0-9,_]*)"#,
        // Anthropic: "input length and `max_tokens` exceed context limit:
        // 195000 + 8192 > 200000"
        #"exceed context limit:\s*[0-9,_]+\s*\+\s*[0-9,_]+\s*>\s*([0-9][0-9,_]*)"#,
        // Ollama / llama.cpp style: "the model's context window (4096)"
        #"context (?:window|length|size)\s*(?:of|is)?\s*\(\s*([0-9][0-9,_]*)\s*\)"#,
        // Generic: "exceeds the model's context window of 32768 tokens"
        #"context (?:window|length|size)\s+of\s+([0-9][0-9,_]*)\s*tokens"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The endpoint's real context window, or `nil` when the text doesn't
    /// contain one.
    ///
    /// Deliberately conservative. An *output* cap ("max_tokens is too
    /// large", "maximum number of output tokens") must never be mistaken
    /// for a context window — recording 8,192 as the window of a 200k
    /// model would make the ring lie and auto-compaction thrash — so every
    /// pattern requires the words "context length/window/size", and text
    /// that only talks about output is left alone.
    static func contextLength(fromErrorText text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text) else { continue }
            let digits = text[captured].filter(\.isNumber)
            guard let value = Int(digits), plausibleRange.contains(value) else { continue }
            return value
        }
        return nil
    }
}
