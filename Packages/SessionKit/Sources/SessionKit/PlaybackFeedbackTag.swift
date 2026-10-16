import Foundation

/// The item and session a feedback event is about (#430). Only work that belongs to one listen sets it:
/// a summary of its Margins, or the transcript of one of its voice Margins. Everything else has no origin
/// and keeps the app's top banner.
public struct FeedbackOrigin: Equatable, Sendable {
    public enum Work: Equatable, Sendable {
        case summary
        case marginTranscription
    }

    public let itemId: String
    public let sessionId: String
    public let work: Work

    public init(itemId: String, sessionId: String, work: Work) {
        self.itemId = itemId
        self.sessionId = sessionId
        self.work = work
    }
}

/// A one-line tag under the playback title, in place of a banner over it (#430). It shows only while the
/// Now screen is playing the event's own item and session; a late failure from another listen keeps the
/// banner, so it can't read as being about what's playing. The full message stays on the item.
public struct PlaybackFeedbackTag: Equatable, Sendable {
    public let text: String
    public let isFailure: Bool
    public let offersRetry: Bool

    /// Nil when the event belongs in the top banner instead.
    public init?(
        kind: FeedbackBannerPolicy.Kind,
        origin: FeedbackOrigin?,
        offersRetry: Bool,
        playbackScreenVisible: Bool,
        playingItemId: String?,
        playingSessionId: String?
    ) {
        guard kind != .success,
              let origin,
              playbackScreenVisible,
              origin.itemId == playingItemId,
              origin.sessionId == playingSessionId else { return nil }
        text = Self.text(for: origin.work, isFailure: kind == .error)
        isFailure = kind == .error
        self.offersRetry = offersRetry
    }

    /// Short enough for one line at the caption size beside Retry. A warning from transcription is
    /// Speech Recognition being off, which TranscriptionFailureWording keeps apart from a failure.
    static func text(for work: FeedbackOrigin.Work, isFailure: Bool) -> String {
        switch (work, isFailure) {
        case (.summary, _):
            "Summary couldn’t finish"
        case (.marginTranscription, true):
            "Margin transcript failed"
        case (.marginTranscription, false):
            "No transcript: Speech Recognition is off"
        }
    }
}
