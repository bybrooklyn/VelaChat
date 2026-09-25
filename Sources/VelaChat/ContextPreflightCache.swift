import Foundation
import VelaCore

struct ContextPreflightSnapshot: Sendable, Equatable {
    let fingerprint: String
    let inputTokens: Int
    let countedAt: Date
    let provider: ProviderKind
    let requestedModel: String

    init(fingerprint: String, count: ProviderInputTokenCount) {
        self.fingerprint = fingerprint
        inputTokens = count.inputTokens
        countedAt = count.countedAt
        provider = count.provider
        requestedModel = count.requestedModel
    }
}

/// Provider token-count endpoints are exact but still network requests. Cache
/// them by the immutable PreparedRequest fingerprint so reopening a popover or
/// retrying an unchanged high-risk send does not spend another rate-limit slot.
actor ContextPreflightCache {
    static let shared = ContextPreflightCache()

    typealias Counter = @Sendable (ProviderProfile, ProviderCredential, PreparedRequest) async throws -> ProviderInputTokenCount

    private var entries: [String: ContextPreflightSnapshot] = [:]
    private var inFlight: [String: Task<ContextPreflightSnapshot, Error>] = [:]
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let counter: Counter

    init(
        lifetime: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        counter: @escaping Counter = { profile, credential, request in
            try await CompatibleChatClient.shared.countInputTokens(
                profile: profile,
                credential: credential,
                preparedRequest: request
            )
        }
    ) {
        self.lifetime = lifetime
        self.now = now
        self.counter = counter
    }

    func count(
        profile: ProviderProfile,
        credential: ProviderCredential,
        request: PreparedRequest,
        force: Bool = false
    ) async throws -> ContextPreflightSnapshot {
        if !force, let existing = entries[request.fingerprint],
           now().timeIntervalSince(existing.countedAt) < lifetime {
            return existing
        }
        if let task = inFlight[request.fingerprint] { return try await task.value }

        let task = Task {
            let count = try await counter(profile, credential, request)
            return ContextPreflightSnapshot(fingerprint: request.fingerprint, count: count)
        }
        inFlight[request.fingerprint] = task
        defer { inFlight[request.fingerprint] = nil }
        let snapshot = try await task.value
        entries[request.fingerprint] = snapshot
        return snapshot
    }

    func cached(fingerprint: String) -> ContextPreflightSnapshot? {
        guard let entry = entries[fingerprint], now().timeIntervalSince(entry.countedAt) < lifetime else {
            entries[fingerprint] = nil
            return nil
        }
        return entry
    }

    func clear() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        entries.removeAll()
    }
}
