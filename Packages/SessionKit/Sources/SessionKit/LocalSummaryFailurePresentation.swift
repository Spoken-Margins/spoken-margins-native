/// Separates a short summary failure notice from the full explanation kept on its item.
public struct LocalSummaryFailurePresentation: Equatable, Sendable {
    public let feedbackMessage: String
    public let detailMessage: String

    public init(errorDescription: String) {
        detailMessage = "On-device summary failed: \(errorDescription) Tap Retry Summary to try the model again."
        feedbackMessage = "Summary couldn’t finish."
    }
}
