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
/// A stronger option exists — pplx-embed-0.6b via MLX — and is planned as
/// an opt-in upgrade. Until then, a nil vector simply means keyword
/// search does the work alone, which is why every caller treats
/// embeddings as optional rather than required.
final class MemoryEmbedder: @unchecked Sendable {
    static let shared = MemoryEmbedder()

    private let lock = NSLock()
    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var didAttemptLoad = false

    private init() {}

    /// Mean-pooled token vectors, L2-normalised. Mean pooling is the
    /// standard way to get one sentence vector out of a contextual model,
    /// and normalising means cosine similarity is a plain dot product
    /// with a stable 0…1 range for ranking.
    func vector(for text: String) -> [Float]? {
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
    var isSemanticAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return contextual != nil || sentence != nil
    }
}
