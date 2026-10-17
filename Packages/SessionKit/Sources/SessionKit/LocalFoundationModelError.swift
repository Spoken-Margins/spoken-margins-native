import Foundation

/// Why the on-device model's reply was rejected or could not be asked for.
public enum LocalFoundationModelError: LocalizedError, Equatable {
    case unavailable(String)
    case emptyResponse
    case invalidStructuredResponse
    case sourceTextUnavailable
    case outputTooLong
    case excessiveSourceQuotation
    case invalidInterjectionSummary

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyResponse: return "The on-device model returned an empty response."
        case .invalidStructuredResponse: return "The on-device model returned an invalid chapter label."
        case .sourceTextUnavailable: return "No source text is available for a Listening Map."
        case .outputTooLong: return "The on-device model returned chapter metadata outside the allowed length."
        case .excessiveSourceQuotation: return "The on-device model copied too much source text into chapter metadata."
        case .invalidInterjectionSummary:
            return "Apple’s on-device model did not produce a concise, grounded summary that passed the completeness checks. No cleaned-transcript fallback was saved. Try again."
        }
    }
}
