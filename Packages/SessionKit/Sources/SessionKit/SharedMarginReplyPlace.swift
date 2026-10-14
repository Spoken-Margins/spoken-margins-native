import Foundation

/// Where the source moves to before a reply to a shared Margin is recorded or written (#473), so the reply is
/// anchored to the moment it answers. A podcast Margin has a time; an article or PDF Margin that the app matched
/// in the listener's text has a character offset. Anything else has no place to send the listener to, so there is
/// no Reply to offer: a reply recorded wherever the source happens to be would be anchored to the wrong passage.
public enum SharedMarginReplyPlace: Equatable, Sendable {
    case media(timeMs: Int)
    case text(charOffset: Int)

    public init?(_ interjection: ImportedCommentaryInterjection) {
        if let position = SharedMarginPlaybackPosition(interjection) {
            self = .media(timeMs: position.mediaTimeMs)
            return
        }
        let resolution = interjection.resolution
        guard resolution.evidenceClass == .articleTextVerified, !resolution.isAmbiguous,
              let start = resolution.localStartChar, start >= 0 else { return nil }
        self = .text(charOffset: start)
    }
}
