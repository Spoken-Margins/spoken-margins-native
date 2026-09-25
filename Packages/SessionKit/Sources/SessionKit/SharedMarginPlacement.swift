import Foundation

/// Placing a shared podcast Margin by ear (#158, slice 6 of #27).
///
/// When matching couldn't place a shared Margin (or only approximately), the recipient can listen around the
/// suggested spot and say "this is the spot". That position is stored as `recipientConfirmed`: it plays inline
/// from then on, but it is never presented as acoustically or transcript verified.
public struct SharedMarginPlacement: Sendable, Equatable {
    /// Start this far before the suggested spot, so the listener hears the lead-up.
    public static let leadInMs = 15_000

    public let layerId: String
    public let interjectionId: String
    public let suggestedMediaTimeMs: Int
    /// Where the suggestion came from: the app's approximate match, or only the sender's timestamp.
    public let suggestionSource: SuggestionSource

    public enum SuggestionSource: String, Sendable, Equatable {
        case approximateMatch
        case senderTimestamp
    }

    public var listenStartMediaTimeMs: Int { max(0, suggestedMediaTimeMs - Self.leadInMs) }

    /// Nil when there's nothing to suggest, or the Margin is already placed by evidence or by the recipient.
    /// `recipientDurationMs` keeps the suggestion inside the recipient's (possibly shorter) edition.
    public init?(interjection: ImportedCommentaryInterjection, recipientDurationMs: Int? = nil) {
        guard Self.needsPlacement(interjection.resolution) else { return nil }
        let approximate = interjection.resolution.isAmbiguous ? nil : interjection.resolution.localMediaTimeMs
        guard let suggested = approximate ?? interjection.anchorEvidence.mediaTimeMs, suggested >= 0 else { return nil }
        layerId = interjection.layerId
        interjectionId = interjection.id
        suggestionSource = approximate == nil ? .senderTimestamp : .approximateMatch
        if let duration = recipientDurationMs, duration > 0 {
            suggestedMediaTimeMs = min(suggested, duration)
        } else {
            suggestedMediaTimeMs = suggested
        }
    }

    /// Placements the listener can improve on by ear.
    public static func needsPlacement(_ resolution: ImportedAnchorResolution) -> Bool {
        if resolution.isAmbiguous { return true }
        switch resolution.evidenceClass {
        case .unresolved, .ambiguous, .absentFromRecipientEdition, .timestampFallback, .mapInterpolated:
            return true
        case .exactEdition, .transcriptVerified, .acousticVerified, .fused, .articleTextVerified, .recipientConfirmed:
            return false
        }
    }

    /// The listener heard the moment at `mediaTimeMs` in their own copy.
    public func confirmedResolution(atMediaTimeMs mediaTimeMs: Int) -> ImportedAnchorResolution {
        ImportedAnchorResolution(
            evidenceClass: .recipientConfirmed,
            localMediaTimeMs: max(0, mediaTimeMs),
            confidence: nil,
            isAmbiguous: false,
            algorithmVersion: "recipient-confirmed.v1"
        )
    }
}
