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

    public init(completedChunks: Int, totalChunks: Int) {
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
    }

    public var percent: Int {
        guard totalChunks > 0 else { return 0 }
        return max(0, min(100, Int(
            (Double(completedChunks) / Double(totalChunks) * 100).rounded()
        )))
    }
}
