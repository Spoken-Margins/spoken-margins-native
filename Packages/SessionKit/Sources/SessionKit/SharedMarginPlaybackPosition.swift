import Foundation

/// Where to play a shared podcast Margin when the listener taps it (#158).
///
/// Uses the best position the recipient has: a match in their own copy, else the sender's time. Anything short
/// of a verified match is marked approximate, so the app never presents a guess as a placement.
public struct SharedMarginPlaybackPosition: Sendable, Equatable {
    public let mediaTimeMs: Int
    public let isApproximate: Bool

    public init?(_ interjection: ImportedCommentaryInterjection) {
        let resolution = interjection.resolution
        if !resolution.isAmbiguous, let local = resolution.localMediaTimeMs, local >= 0 {
            switch resolution.evidenceClass {
            case .exactEdition, .transcriptVerified, .acousticVerified, .fused, .recipientConfirmed:
                self.init(mediaTimeMs: local, isApproximate: false)
                return
            case .mapInterpolated, .timestampFallback:
                self.init(mediaTimeMs: local, isApproximate: true)
                return
            case .articleTextVerified, .ambiguous, .absentFromRecipientEdition, .unresolved:
                break
            }
        }
        guard let sender = interjection.anchorEvidence.mediaTimeMs, sender >= 0 else { return nil }
        self.init(mediaTimeMs: sender, isApproximate: true)
    }

    public init(mediaTimeMs: Int, isApproximate: Bool) {
        self.mediaTimeMs = mediaTimeMs
        self.isApproximate = isApproximate
    }
}
