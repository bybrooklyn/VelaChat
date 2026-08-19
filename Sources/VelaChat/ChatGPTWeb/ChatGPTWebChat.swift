import Foundation

/// Streaming conversation turns over ChatGPT Web. The real SSE
/// implementation lands with the streaming phase — this placeholder
/// keeps the checkpoint honest instead of routing ChatGPT sends into
/// the OpenAI-compatible path, which would silently 404.
enum ChatGPTWebChat {
    static func stream(
        model: String,
        thinking: ThinkingLevel,
        messages: [ChatMessage],
        onEvent: @escaping @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        throw APIError.message("ChatGPT chat is still being wired up — sign-in and model discovery already work; streaming replies land in the next build.")
    }
}
