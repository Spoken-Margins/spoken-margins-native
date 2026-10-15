import Foundation

public enum RenderedSpeechGenerationState: String, Equatable, Sendable {
    case inactive
    case rendering
    case ready
    case stopped
}

extension RenderedSpeechGenerationState {
    /// The player's on-device voice line. A stop says why (#314).
    public func listenerDescription(
        progress: RenderedSpeechGenerationProgress,
        isDelayed: Bool,
        stopReason: String?,
        fallbackReason: SpeechFallbackReason?
    ) -> String {
        switch self {
        case .rendering:
            guard progress.totalChunks > 0 else {
                return "Preparing the full Supertonic audio on this iPhone"
            }
            if isDelayed {
                return "Still preparing part \(min(progress.completedChunks + 1, progress.totalChunks)) of \(progress.totalChunks) · \(progress.percent)% complete"
            }
            return "Generating full audio · \(progress.percent)% (\(progress.completedChunks) of \(progress.totalChunks) parts)"
        case .ready:
            return "Prepared audio is ready for playback"
        case .stopped:
            return SpeechGenerationStopReason.listenerExplanation(stopReason: stopReason, fallbackReason: fallbackReason)
        case .inactive:
            return "On-device voice generation is inactive"
        }
    }
}

public struct RenderedSpeechGenerationProgress: Equatable, Sendable {
    public var completedChunks: Int
    public var totalChunks: Int
    /// The render chain is resting on purpose with enough listening rendered ahead (#1681), so no progress is due.
    public var isRestingAhead: Bool

    public init(completedChunks: Int, totalChunks: Int, isRestingAhead: Bool = false) {
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.isRestingAhead = isRestingAhead
    }

    /// Whether a stall in this progress means rendering is slow: chunks remain and the chain isn't resting. A rest
    /// reported "Still preparing" and a delay in diagnostics on every pause (#1681 audit).
    public var watchesForDelay: Bool {
        completedChunks < totalChunks && !isRestingAhead
    }

    public var percent: Int {
        guard totalChunks > 0 else { return 0 }
        return max(0, min(100, Int(
            (Double(completedChunks) / Double(totalChunks) * 100).rounded()
        )))
    }
}
