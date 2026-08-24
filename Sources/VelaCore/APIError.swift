import Foundation

/// Extracted ahead of the rest of `ChatAPI.swift` (which lands in a later
/// wave) because `EgressPolicy.check` (`Redaction.swift`) and
/// `MemoryEmbedder`'s HTTP calls both need to throw it, and neither of
/// those can depend on a VelaChat-side type.
public enum APIError: Error, LocalizedError {
    case status(Int, String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .status(let code, let detail):
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return "Request failed (\(code)).\(suffix)"
        case .message(let message): return message
        }
    }
}
