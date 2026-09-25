import XCTest
@testable import VelaChat
import VelaCore

final class ContextPreflightCacheTests: XCTestCase {
    private actor Probe {
        var calls = 0
        func count(profile: ProviderProfile, request: PreparedRequest) async throws -> ProviderInputTokenCount {
            calls += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            return ProviderInputTokenCount(inputTokens: 123, provider: profile.kind, requestedModel: request.wireModel)
        }
    }

    func testFingerprintCacheDeduplicatesInFlightAndForceRefreshes() async throws {
        let probe = Probe()
        let cache = ContextPreflightCache(counter: { profile, _, request in
            try await probe.count(profile: profile, request: request)
        })
        let profile = ProviderProfile(kind: .openAI, name: "OpenAI", endpoint: "https://api.openai.com/v1")
        let request = PreparedRequest(
            profile: profile,
            requestedModel: "gpt-test",
            wireModel: "gpt-test",
            thinking: .auto,
            messages: [ChatMessage(role: "user", content: "hello")],
            tools: [],
            requestedOutputTokens: 0
        )
        let credential = ProviderCredential(token: "test", accountID: nil, isCodexOAuth: false)

        async let first = cache.count(profile: profile, credential: credential, request: request)
        async let second = cache.count(profile: profile, credential: credential, request: request)
        let firstValue = try await first
        let secondValue = try await second
        let values = [firstValue, secondValue]
        XCTAssertEqual(values.map(\.inputTokens), [123, 123])
        var calls = await probe.calls
        XCTAssertEqual(calls, 1)

        _ = try await cache.count(profile: profile, credential: credential, request: request)
        calls = await probe.calls
        XCTAssertEqual(calls, 1)
        _ = try await cache.count(profile: profile, credential: credential, request: request, force: true)
        calls = await probe.calls
        XCTAssertEqual(calls, 2)

        await cache.clear()
        let cached = await cache.cached(fingerprint: request.fingerprint)
        XCTAssertNil(cached)
    }
}
