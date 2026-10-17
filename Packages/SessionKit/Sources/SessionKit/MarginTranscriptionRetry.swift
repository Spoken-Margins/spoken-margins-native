import Foundation

/// Whether retranscribing a Margin still makes sense (#430). A failed transcription's Retry holds the Margin
/// as it was when the failure was posted. The listener can delete that Margin, or move its item to Recently
/// Deleted, before tapping. The answer comes from the Margin as stored now, never from that copy, so every
/// path to a Retry (the feedback, the Margin row) agrees and a deleted Margin can't be transcribed again.
public enum MarginTranscriptionRetry {
    public enum Verdict: Equatable, Sendable {
        /// The Margin is live and has a recording to read.
        case retry
        /// The Margin, or the item it belongs to, was deleted or is gone from the store.
        case gone
        /// The Margin is live but has no recording (a written Margin, or the audio is missing).
        case noAudio
    }

    /// - Parameters:
    ///   - current: the Margin as stored now, nil when it can't be found.
    ///   - itemDeletedAt: when its item was moved to Recently Deleted, nil while the item is live.
    public static func verdict(current: Interjection?, itemDeletedAt: Date?) -> Verdict {
        guard let current, current.status != "deleted", itemDeletedAt == nil else { return .gone }
        guard current.captureKind != .written, current.audioPath != nil else { return .noAudio }
        return .retry
    }
}
