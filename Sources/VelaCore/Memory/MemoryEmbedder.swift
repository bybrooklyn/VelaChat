import Foundation
import NaturalLanguage

/// Turns text into a vector, on device.
///
/// Uses `NLEmbedding.sentenceEmbedding`, which is trained for sentence
/// similarity, rather than mean-pooled `NLContextualEmbedding` token
/// vectors. That choice was measured, not assumed: mean-pooled contextual
/// vectors put every pair of English sentences in a 0.77-0.89 cosine band
/// — for the query "how should we look things up — meaning or exact
/// words?", a sentence about pizza dough scored HIGHER (0.855) than the
/// correct answer about hybrid search (0.852). The sentence embedding
/// separates the same cases cleanly (0.274 vs 0.140), and ranks the right
/// answer first on most queries.
///
/// It runs on device, so this costs no money, needs no network, and never
/// sends a word of the user's history anywhere — which matters more here
/// than raw quality, because this indexes everything they have ever typed.
///
/// A stronger option exists and is a functional requirement, not a nicety
/// — see `RemoteEmbedding` below and `isRemoteEnabled`. It is opt-in and
/// off by default because it is the one part of memory that would send
/// the user's text off the machine. Until it is wired into the store, a
/// nil vector simply means keyword search does the work alone, which is
/// why every caller treats embeddings as optional rather than required.
public final class MemoryEmbedder: @unchecked Sendable {
    public static let shared = MemoryEmbedder()

    private let lock = NSLock()
    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var didAttemptLoad = false

    private init() {}

    /// Mean-pooled token vectors, L2-normalised. Mean pooling is the
    /// standard way to get one sentence vector out of a contextual model,
    /// and normalising means cosine similarity is a plain dot product
    /// with a stable 0…1 range for ranking.
    public func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A long message would otherwise be dominated by whatever it
        // trails off into; the opening is the part that says what it's about.
        let capped = String(trimmed.prefix(2_000))

        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        if let sentence, let vector = sentence.vector(for: capped) {
            return normalise(vector.map(Float.init))
        }
        // Contextual mean pooling only as a last resort — see the note
        // above about how poorly it discriminates.
        if let contextual, let vector = try? pooledVector(from: contextual, text: capped) {
            return vector
        }
        return nil
    }

    private func loadIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true
        sentence = NLEmbedding.sentenceEmbedding(for: .english)
        guard sentence == nil else { return }
        if let embedding = NLContextualEmbedding(language: .english), embedding.hasAvailableAssets,
           (try? embedding.load()) != nil {
            contextual = embedding
        }
    }

    private func pooledVector(from embedding: NLContextualEmbedding, text: String) throws -> [Float] {
        let result = try embedding.embeddingResult(for: text, language: .english)
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            guard vector.count == sum.count else { return true }
            for index in vector.indices { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { throw EmbeddingError.empty }
        return normalise(sum.map { Float($0 / Double(count)) })
    }

    private func normalise(_ vector: [Float]) -> [Float] {
        let magnitude = vector.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard magnitude > 0 else { return vector }
        return vector.map { Float(Double($0) / magnitude) }
    }

    private enum EmbeddingError: Error { case empty }

    /// Whether semantic recall is actually available — surfaced in
    /// Settings so "memory seems worse than expected" has a visible
    /// explanation instead of being a mystery.
    public var isSemanticAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return contextual != nil || sentence != nil
    }
}

// MARK: - Opt-in hosted embeddings

/// The upgrade path out of on-device embeddings.
///
/// The measurement that shaped this whole subsystem is that
/// `NLEmbedding.sentenceEmbedding` cannot retrieve on its own: the query
/// "zzzqqq unrelated gibberish xyzzy" scored an unrelated note at 0.279,
/// higher than the correct hit for a real question at 0.274. A real
/// embedding model fixes that, and every hosted one lives on somebody
/// else's computer.
///
/// So this is opt-in, off by default, stated plainly in Settings, and
/// gated on `EgressPolicy` — memory text is the most personal corpus the
/// app holds, and "local-only mode" has to mean it about this too. The
/// check is inside `vector(for:)` rather than at the call site so no
/// future caller can forget it.
///
/// The wire shape is the OpenAI `/v1/embeddings` one (`{"input": …,
/// "model": …}` → `{"data": [{"embedding": [Float]}]}`), which is what
/// every hosted embedding endpoint worth pointing at speaks. Per
/// AGENTS.md, "OpenAI-compatible" is a claim rather than a guarantee, so
/// `verify()` exists to make an endpoint prove it before the user trusts
/// it with anything.
public struct RemoteEmbedding: Sendable {
    public var endpoint: URL
    public var model: String
    public var apiKey: String

    /// Reads the stored opt-in. False unless the user explicitly turned it
    /// on: nothing about memory should start leaving the Mac because a
    /// default flipped.
    public static var isEnabled: Bool {
        Defaults.bool(DefaultsKey.remoteEmbeddingsEnabled, default: false)
    }

    /// The configured endpoint, or nil when the opt-in is off or the
    /// settings are incomplete. `apiKey` is supplied by the caller because
    /// keys live in the Keychain behind `ProviderStore`, never here.
    public static func configured(apiKey: String) -> RemoteEmbedding? {
        guard isEnabled else { return nil }
        guard let raw = Defaults.string(DefaultsKey.remoteEmbeddingEndpoint),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else { return nil }
        let model = (Defaults.string(DefaultsKey.remoteEmbeddingModel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return RemoteEmbedding(endpoint: url, model: model, apiKey: apiKey)
    }

    /// One vector for one string. Throws rather than returning nil so a
    /// blocked egress, a dead endpoint and an unparseable answer stay
    /// distinguishable — a silent nil here would read as "this text just
    /// isn't embeddable" and hide a misconfiguration forever.
    public func vector(for text: String) async throws -> [Float] {
        // The gate, before anything is serialised, let alone sent.
        try EgressPolicy.check(endpoint)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Limits.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["model": model, "input": String(text.prefix(8_000))]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.message("Embedding endpoint returned \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]],
              let numbers = entries.first?["embedding"] as? [Double], !numbers.isEmpty else {
            throw APIError.message("Embedding endpoint did not return an OpenAI-shaped {\"data\":[{\"embedding\":[…]}]} body.")
        }
        return numbers.map(Float.init)
    }

    /// What the Settings "Test" button calls: returns the dimension the
    /// endpoint actually produced, so the user sees proof rather than a
    /// green tick that only means "the request didn't throw".
    public func verify() async -> Result<Int, Error> {
        do {
            return .success(try await vector(for: "User prefers concise answers.").count)
        } catch {
            return .failure(error)
        }
    }
}
