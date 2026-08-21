import Foundation
import VelaCore

/// A durable fact that persists across every conversation, not just the one
/// it was learned in. Global rather than per-conversation, on purpose: the
/// whole point is that it follows you everywhere. Written and maintained by
/// the model itself through the memory tools (`save_memory` /
/// `search_memory` / `edit_memory`) — Settings is the user's control
/// surface to see, edit, and delete everything stored. On-device only.
///
/// This is a *value* type, not a store. Facts live in `MemoryStore`
/// (SQLite) and nowhere else; `AppModel.facts` holds these as a read
/// mirror the UI can render synchronously. It stays `Codable` because it
/// is also the shape of the pre-store `velachat.memories` array that
/// `LegacyMemoryMigration` decodes once and then deletes.
struct MemoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var content: String
    var createdAt: Date
    /// Project/topic grouping — supplied by the model when saving, editable
    /// by the user in Settings. `nil` groups under "General" (and on every
    /// memory saved before this field existed).
    var topic: String?

    init(id: UUID = UUID(), content: String, createdAt: Date = Date(), topic: String? = nil) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.topic = topic
    }

    var displayTopic: String {
        let trimmed = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "General" : trimmed
    }
}

// MARK: - Phrasing

/// Rewrites a fact into the one shape every stored fact should have: a
/// third-person, subject-first statement about the user —
/// `User prefers concise answers`, `User works mainly in Swift`.
///
/// This runs on *write*, never on read, for two reasons. Facts saved
/// before this existed are a grab-bag of voices ("I prefer…",
/// "prefers…", "The user works…", "my main language is…"), and a list
/// that mixes them reads like three different people wrote it. More
/// importantly, dedupe (`MemoryStore.saveFact`) compares texts token by
/// token: without a canonical subject, "I prefer dark mode" and "User
/// prefers dark mode" are two rows that will never recognise each other.
///
/// Pure and static so it can be unit-tested directly, with no store, no
/// database, and no model call.
enum MemoryPhrasing {
    /// Idempotent: normalising an already-normalised fact returns it
    /// unchanged, which is what makes it safe to run on every write
    /// including the legacy migration's re-save.
    static func normalize(_ raw: String) -> String {
        var text = collapsingWhitespace(raw)
        text = strippingWrappingQuotes(text)
        text = strippingPreamble(text)
        guard !text.isEmpty else { return "" }
        text = rewritingSubject(text)
        // A trailing comma or semicolon is a fragment marker left behind by
        // a preamble strip ("Remember that, ..."), never real punctuation
        // at the end of a statement.
        while let last = text.last, last == "," || last == ";" {
            text.removeLast()
        }
        return capitalizingFirstLetter(text)
    }

    /// Word set used for dedupe comparison: case-folded, punctuation-free,
    /// and with the canonical subject removed so "User prefers X" and
    /// "User strongly prefers X" are compared on what actually differs.
    static func comparisonTokens(_ text: String) -> Set<String> {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .filter { $0 != "user" && $0 != "users" && $0 != "the" && $0 != "a" && $0 != "an" }
        return Set(words)
    }

    /// Jaccard overlap of the two token sets, 0…1.
    ///
    /// Deliberately blunt and deliberately conservative. The threshold it
    /// feeds (`MemoryStore.duplicateSimilarity`, 0.7) was picked against
    /// the pairs that must NOT merge — measured: "User has two cats" vs
    /// "User has two dogs" scores 0.5, "User works in Swift" vs "User
    /// works in Rust" 0.5, "…concise answers" vs "…concise replies" 0.5 —
    /// against the restatements that must: "User works in Swift" vs "User
    /// works mainly in Swift" 0.75, "User prefers concise answers" vs
    /// "User strongly prefers concise answers" 0.75. A missed merge costs
    /// a duplicate row; a wrong merge destroys a true fact.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = comparisonTokens(a)
        let right = comparisonTokens(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(shared) / Double(union)
    }

    // MARK: Steps

    private static func collapsingWhitespace(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func strippingWrappingQuotes(_ text: String) -> String {
        var result = text
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")]
        for (open, close) in pairs where result.count >= 2 && result.first == open && result.last == close {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Models routinely wrap a fact in a note to themselves. The fact is
    /// what gets stored; the note is noise that would also poison the
    /// dedupe token comparison.
    private static let preambles = [
        "remember that ", "remember: ", "remember, ", "please remember that ", "please remember ",
        "note that ", "note: ", "noting that ", "fyi ", "fyi: ", "the fact that ",
        "important: ", "keep in mind that ", "for future reference ", "for future reference, ",
    ]

    private static func strippingPreamble(_ text: String) -> String {
        var result = text
        var didStrip = true
        // Repeat: "Note: remember that ..." happens.
        while didStrip {
            didStrip = false
            let lowered = result.lowercased()
            for preamble in preambles where lowered.hasPrefix(preamble) {
                result = String(result.dropFirst(preamble.count)).trimmingCharacters(in: .whitespaces)
                didStrip = true
                break
            }
        }
        return result
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func splitFirstWord(_ text: String) -> (first: String, rest: String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[text.startIndex..<space]), String(text[text.index(after: space)...]))
    }

    private static func joined(_ head: String, _ rest: String) -> String {
        rest.isEmpty ? head : head + " " + rest
    }

    /// The heart of it: give the statement the subject "User".
    ///
    /// Anything whose subject can't be identified is left alone rather
    /// than mangled — "Brooklyn prefers teal accents" is already a
    /// third-person subject-first statement, and prefixing it would
    /// produce "User Brooklyn prefers…". Only a recognised pronoun
    /// subject, a recognised bare verb, or an existing "User" prefix is
    /// rewritten.
    private static func rewritingSubject(_ text: String) -> String {
        let (first, rest) = splitFirstWord(text)
        let lower = first.lowercased()

        switch lower {
        case "user":
            return joined("User", rest)
        case "user's", "users", "users'":
            return joined("User's", rest)
        case "the":
            // "The user prefers…" → recurse on the rest, which starts with
            // the pronoun proper.
            let (second, tail) = splitFirstWord(rest)
            let secondLower = second.lowercased()
            if secondLower == "user" || secondLower == "user's" || secondLower == "users" {
                return rewritingSubject(joined(second, tail))
            }
            return text
        case "i":
            return joined("User", conjugatingLeadingVerb(in: rest))
        case "i'm", "im":
            return joined("User is", rest)
        case "i've":
            return joined("User has", rest)
        case "i'd":
            return joined("User would", rest)
        case "i'll":
            return joined("User will", rest)
        case "my":
            return joined("User's", rest)
        case "they":
            return joined("User", conjugatingLeadingVerb(in: rest))
        case "he", "she":
            return joined("User", rest)
        case "their", "his", "her":
            return joined("User's", rest)
        default:
            break
        }

        // A bare verb phrase — the shape `save_memory`'s own examples use
        // ("Prefers Swift over Objective-C").
        let bare = lower.trimmingCharacters(in: CharacterSet.letters.inverted)
        if participleStarters.contains(bare) {
            return joined("User is", joined(bare, rest))
        }
        if isRecognisedVerb(bare) {
            return joined("User " + thirdPerson(bare), rest)
        }
        return text
    }

    // MARK: Conjugation

    /// Conjugates the verb in a first/second-person predicate, stepping
    /// over any adverbs in front of it: "strongly prefer concise answers"
    /// has to become "strongly prefers concise answers", not "strongly
    /// prefer" (wrong) or "stronglys prefer" (worse). Two adverbs is the
    /// most anyone writes before giving up.
    private static func conjugatingLeadingVerb(in predicate: String) -> String {
        var leading: [String] = []
        var remainder = predicate
        for _ in 0..<3 {
            let (word, tail) = splitFirstWord(remainder)
            guard !word.isEmpty else { break }
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
            if isRecognisedVerb(bare) {
                return joined((leading + [thirdPerson(word)]).joined(separator: " "), tail)
            }
            guard isAdverb(bare) else { break }
            leading.append(word)
            remainder = tail
        }
        // No verb this file recognises — leave the predicate untouched
        // rather than guess at its grammar.
        return predicate
    }

    private static func isRecognisedVerb(_ bare: String) -> Bool {
        irregulars[bare] != nil || modals.contains(bare) || baseVerbs.contains(bare) || thirdPersonForms.contains(bare)
    }

    /// "-ly" catches most of them; the rest are the handful of common
    /// adverbs that don't end in it.
    private static func isAdverb(_ bare: String) -> Bool {
        bare.hasSuffix("ly") || ["always", "never", "often", "sometimes", "still", "also", "just", "rarely"].contains(bare)
    }

    /// Turning "I prefer" into "User prefer" is worse than not rewriting
    /// at all, so the subject swap carries the verb with it. Only verbs
    /// this file recognises are conjugated; anything else is returned
    /// untouched, original casing and all, on the assumption that it is
    /// already in third person.
    static func thirdPerson(_ verb: String) -> String {
        let lower = verb.lowercased()
        if let irregular = irregulars[lower] { return irregular }
        if modals.contains(lower) { return lower }
        guard baseVerbs.contains(lower) else { return verb }
        return addingThirdPersonSuffix(lower)
    }

    private static func addingThirdPersonSuffix(_ verb: String) -> String {
        if verb.hasSuffix("s") || verb.hasSuffix("x") || verb.hasSuffix("z")
            || verb.hasSuffix("ch") || verb.hasSuffix("sh") || verb.hasSuffix("o") {
            return verb + "es"
        }
        if verb.hasSuffix("y"), let beforeY = verb.dropLast().last, !"aeiou".contains(beforeY) {
            return verb.dropLast() + "ies"
        }
        return verb + "s"
    }

    private static let irregulars: [String: String] = [
        "am": "is", "are": "is", "is": "is", "be": "is",
        "have": "has", "has": "has",
        "do": "does", "does": "does",
        "was": "was", "were": "was",
        "don't": "doesn't", "dont": "doesn't", "doesn't": "doesn't",
    ]

    private static let modals: Set<String> = [
        "can", "could", "will", "would", "should", "shall", "must", "might", "may",
    ]

    /// Fragments that are really "is <participle>": "Based in Berlin",
    /// "Working mainly in Swift".
    private static let participleStarters: Set<String> = [
        "based", "located", "interested", "studying", "learning", "training",
        "living", "building", "planning", "considering", "employed", "married",
    ]

    /// Present-tense verbs a durable fact about a person is actually built
    /// from. Curated rather than inferred: an `NLTagger` lookup would make
    /// this function environment-dependent, and a normalizer whose output
    /// changes with which language assets happen to be installed cannot be
    /// tested or trusted.
    private static let baseVerbs: Set<String> = [
        "prefer", "like", "love", "hate", "dislike", "enjoy", "want", "need",
        "use", "avoid", "work", "live", "write", "read", "build", "run", "own",
        "drive", "ride", "speak", "study", "teach", "play", "code", "program",
        "ship", "deploy", "manage", "lead", "follow", "keep", "hold", "care",
        "focus", "wake", "sleep", "eat", "drink", "travel", "commute", "pay",
        "save", "spend", "learn", "practice", "train", "exercise", "cook",
        "bake", "paint", "draw", "sing", "watch", "listen", "stay", "tend",
        "mind", "expect", "plan", "consider", "believe", "think", "know",
        "understand", "remember", "value", "dread", "collect", "maintain",
    ]

    /// Derived once so "prefers" is recognised as a verb start without the
    /// list having to spell out both forms and drift between them.
    private static let thirdPersonForms: Set<String> = Set(baseVerbs.map(addingThirdPersonSuffix))
}

// MARK: - Capture rules

/// What `save_memory` is allowed to write.
///
/// The observed failure was volume: the model saved something on almost
/// every turn, most of it task state ("User is debugging the recall
/// query today") or a restatement of what it had itself just said. Both
/// are worthless next month, and both crowd real facts out of the prompt
/// budget that `relevantMemoryText` has to spend.
///
/// The tool description says all this in prose, but prose is a request.
/// This is the enforcement: obvious violations are refused at the write
/// path, with a reason the model can act on, so the rule holds even when
/// the model doesn't feel like following it.
///
/// One rule in the tool description is deliberately *not* enforced here:
/// "don't save anything already present in the conversation" isn't
/// decidable from the fact alone — the write path never sees the
/// transcript. Duplicates of things already *stored* are handled instead,
/// by dedupe in `MemoryStore.saveFact`.
enum MemoryCapture {
    enum Rejection: Equatable, Sendable {
        case empty
        case tooShort
        case tooLong(Int)
        /// Something true today and meaningless next month.
        case taskState(String)
        /// The model's own output, saved back as if it were a user fact.
        case assistantOutput(String)
        case question
        /// A credential matched one of the built-in redaction patterns.
        case secret(String)

        /// What the tool returns to the model. Every case names the fix,
        /// because "rejected" alone just produces a retry of the same
        /// thing.
        var message: String {
            switch self {
            case .empty:
                return "Error: the memory content is empty."
            case .tooShort:
                return "Error: that's too short to be a fact. Save one complete statement about the user, e.g. \"Prefers concise answers\"."
            case .tooLong(let limit):
                return "Error: that's longer than \(limit) characters. A memory is one short standalone fact, not a summary — split it or save only the durable part."
            case .taskState(let phrase):
                return "Error: \"\(phrase)\" makes this task state, not a durable fact. Save only what will still be true next month — stable preferences, identity, standing constraints."
            case .assistantOutput(let phrase):
                return "Error: \"\(phrase)\" describes your own output, not a fact about the user. Memory is for what the user is and prefers, not for what you just said."
            case .question:
                return "Error: a question isn't a fact. Save the answer, as a statement about the user."
            case .secret(let rule):
                return "Error: that looks like a credential (\(rule)). Never save secrets to memory."
            }
        }
    }

    /// Runs against the *raw* text, before `MemoryPhrasing.normalize`.
    /// Order matters: normalization rewrites "I " to "User ", which would
    /// disguise exactly the assistant-voice sentences this has to catch.
    static func rejection(for raw: String) -> Rejection? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.count > Limits.memoryFactCharacters { return .tooLong(Limits.memoryFactCharacters) }
        if trimmed.hasSuffix("?") { return .question }

        let folded = fold(trimmed)
        for phrase in assistantVoicePhrases where folded.contains(fold(phrase)) {
            return .assistantOutput(phrase)
        }
        for phrase in taskStatePhrases where folded.contains(fold(phrase)) {
            return .taskState(phrase)
        }

        // Length is checked against the *normalized* form: "Remember that
        // I like tea" is long enough raw and nearly empty once the
        // preamble comes off.
        let normalized = MemoryPhrasing.normalize(trimmed)
        guard !normalized.isEmpty else { return .empty }
        let words = normalized.components(separatedBy: " ").filter { !$0.isEmpty }
        if normalized.count < 10 || words.count < 2 { return .tooShort }

        // The built-in credential patterns are already the app's definition
        // of "this must not leave the machine"; a fact is forever, so it
        // must not capture one either.
        let redaction = Redactor(rules: RedactionRule.builtIns()).redact(trimmed)
        if let span = redaction.spans.first { return .secret(span.ruleName) }

        return nil
    }

    /// Matching is done on a folded string — lowercased, apostrophes
    /// removed, every other non-alphanumeric turned into a space, and
    /// padded with spaces — so a phrase only matches on word boundaries
    /// ("todo" must not fire inside "todos-and-donts").
    private static func fold(_ text: String) -> String {
        let stripped = text.lowercased().replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let words = stripped
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return " " + words.joined(separator: " ") + " "
    }

    /// Markers of "true right now" rather than "true about this person".
    /// Chosen for precision over coverage: every phrase here is one that
    /// makes a *durable* fact read wrong, so a false rejection is close to
    /// impossible and the model just rephrases.
    static let taskStatePhrases = [
        "today", "tomorrow", "yesterday", "tonight",
        "this morning", "this afternoon", "this evening",
        "right now", "just now", "at the moment", "for now", "so far",
        "this session", "this conversation", "this chat", "this thread", "this task",
        "next step", "in progress", "todo",
        "currently working on", "working on right now",
        "asked me to", "wants me to", "needs me to", "told me to",
        "just asked", "just said", "we are working on", "were working on",
    ]

    /// The model describing itself. A saved memory in this voice is a
    /// self-reinforcing loop: it recalls its own summary as if the user
    /// had stated it.
    static let assistantVoicePhrases = [
        "i suggested", "i recommended", "i told", "i explained", "i mentioned",
        "i said", "i wrote", "i created", "i generated", "i provided", "i helped",
        "as i mentioned", "as i said", "my previous", "the assistant", "as an ai",
    ]
}

// MARK: - Legacy migration

/// Moves the pre-store `velachat.memories` array into `MemoryStore` once,
/// then deletes it.
///
/// Facts used to live in two places at the same time: an array on
/// `AppModel` persisted to `UserDefaults`, *mirrored* into the store so
/// retrieval had something to search. Two sources of truth for the same
/// data is its own bug — an edit that reached one and not the other left
/// the user's memory list and the model's recall permanently disagreeing.
///
/// The delete is what makes this a real cut rather than a second mirror,
/// and it is also the one thing that can go irreversibly wrong. So the
/// order is: write everything, read all of it back, verify every single
/// fact is present with the content it should have, and only then remove
/// the legacy copy. A verification failure leaves the legacy array
/// completely untouched and the migration flag unset, so the next launch
/// tries again from an intact source.
enum LegacyMemoryMigration {
    /// Returns whether the migration is complete — either it just
    /// finished and verified, or there was nothing to migrate, or it had
    /// already run. `false` means the legacy data is still there,
    /// untouched, and will be retried.
    @discardableResult
    static func run(store: MemoryStore, defaults: UserDefaults) async -> Bool {
        if defaults.object(forKey: DefaultsKey.memoriesMigrationV1) != nil { return true }

        guard let data = defaults.data(forKey: DefaultsKey.memories),
              let legacy = try? JSONDecoder().decode([MemoryItem].self, from: data) else {
            // Nothing was ever stored under the old key (or it is
            // unreadable, in which case there is nothing to lose either).
            defaults.set(true, forKey: DefaultsKey.memoriesMigrationV1)
            return true
        }

        // A fact whose content normalizes to nothing carries no
        // information; it is dropped rather than allowed to block the
        // migration forever on a value that could never be verified.
        let expected: [(id: UUID, content: String, topic: String?)] = legacy.compactMap { item in
            let normalized = MemoryPhrasing.normalize(item.content)
            guard !normalized.isEmpty else { return nil }
            return (item.id, normalized, item.topic)
        }

        for fact in expected {
            await store.upsertFact(id: fact.id, content: fact.content, topic: fact.topic)
        }

        let stored = await store.allFacts()
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.content) })
        for fact in expected where byID[fact.id] != fact.content {
            // Something did not land — a closed database, a failed write,
            // a disk full. Leave everything exactly as it was.
            return false
        }

        defaults.removeObject(forKey: DefaultsKey.memories)
        defaults.set(true, forKey: DefaultsKey.memoriesMigrationV1)
        return true
    }
}
