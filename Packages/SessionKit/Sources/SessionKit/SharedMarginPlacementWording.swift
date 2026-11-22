import Foundation

/// #1974: where a shared Margin sits, in words a recipient can tell apart. One function so the Margins tab,
/// the Timeline and the import sheet say the same thing, and none of them prints a character offset or an
/// enum name.
public enum SharedMarginPlacementWording {
    public static let placed = "Placed here"
    public static let approximate = "Placed roughly here"
    public static let confirmed = "Placed where you confirmed"
    public static let couldntPlace = "Couldn't place this one. Tap to listen anyway."
    public static let playsAfterOthers = "Plays after the others"
    public static let approximatePositionNote = "Approximate position: ads can differ between copies."

    /// The row words for a podcast Margin (#3789): one of three phrases, from where it plays now. Nil when it isn't
    /// offered, so the caller keeps its own words.
    public static func podcastLine(for plan: SharedMarginPlacementPlan) -> String? {
        switch plan {
        case .placed: placed
        case .roughly: approximate
        case .afterOthers: playsAfterOthers
        case .notPlayable: nil
        }
    }

    /// The words for one friend's Margin on a podcast layer, whatever the placement pass is doing: where it plays
    /// now. Nil for any other layer, which keeps `line(for:)`.
    public static func line(
        for interjection: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, durationMs: Int?
    ) -> String? {
        guard layer.itemIdentity.itemType == .podcast else { return nil }
        return podcastLine(for: SharedMarginPrompts.plan(interjection, in: layer, durationMs: durationMs))
    }

    /// The clock time a Margin plays at ("12:34"), or nil when it has none: plays after the others, or isn't offered.
    public static func clock(for plan: SharedMarginPlacementPlan) -> String? {
        switch plan {
        case .placed(let ms?), .roughly(let ms?):
            let totalSeconds = max(0, ms / 1_000)
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        case .placed(nil), .roughly(nil), .afterOthers, .notPlayable:
            return nil
        }
    }

    /// The pinned card's caution while a Margin counts down: only for a best-guess place.
    public static func pinnedCardLine(for plan: SharedMarginPlacementPlan) -> String? {
        if case .roughly = plan { approximatePositionNote } else { nil }
    }

    /// The pinned card's line for a Margin that is counting down (#4175): for a best-guess place at the sender's own
    /// clock, how far apart the two copies' lengths are, when both are known and differ; otherwise the generic caution;
    /// nil for any other plan. A Margin shifted by its matched neighbours (`atSenderClock` false) has the ad difference
    /// taken out already, so it never gets the length note.
    public static func pinnedCardLine(
        for plan: SharedMarginPlacementPlan, atSenderClock: Bool, senderCopyMs: Int?, listenerCopyMs: Int?,
        subject: PinnedMarginCard.Subject
    ) -> String? {
        guard case .roughly = plan else { return nil }
        guard atSenderClock, let difference = CopyLengthDifference(senderMs: senderCopyMs, listenerMs: listenerCopyMs) else {
            return approximatePositionNote
        }
        return copyLengthNote(difference, whose: subject.buttonName.map { "\($0)'s" } ?? "your friend's")
    }

    /// "Your copy is about 35 seconds shorter than Cole's, so Margins may be that far off." The web says the same with a
    /// curly apostrophe (#4614). The words name the size of the length difference; a given Margin can be off by less.
    static func copyLengthNote(_ difference: CopyLengthDifference, whose: String) -> String {
        let ending = difference.farApart ? "so Margins may not line up." : "so Margins may be that far off."
        return "Your copy is \(difference.amount) \(difference.direction.rawValue) than \(whose), \(ending)"
    }

    /// - Parameter paragraph: the 1-based paragraph the resolution's text offset falls in, when the caller
    ///   can compute it (`MarginPlaceIndex.paragraph(atChar:)`). A text offset with no paragraph is described
    ///   by how well it was placed, never by the offset.
    public static func line(for resolution: ImportedAnchorResolution, paragraph: Int? = nil) -> String {
        if resolution.isAmbiguous { return couldntPlace }
        switch resolution.evidenceClass {
        case .unresolved, .absentFromRecipientEdition, .ambiguous:
            return couldntPlace
        case .timestampFallback, .mapInterpolated:
            return approximate
        case .recipientConfirmed:
            return confirmed
        case .exactEdition, .articleTextVerified, .transcriptVerified, .acousticVerified, .fused:
            if resolution.localStartChar != nil, let paragraph, paragraph > 0 { return "Near paragraph \(paragraph)" }
            return placed
        }
    }

    /// The import sheet's position line: the clock time when the Margin is placed at a media time, otherwise
    /// `line(for:)`. A Margin that couldn't be placed never gets a clock, whatever media time its evidence
    /// carried: an ambiguous podcast match still holds its strongest candidate's time (#1974 audit).
    public static func importSheetLine(for resolution: ImportedAnchorResolution, paragraph: Int? = nil) -> String {
        if line(for: resolution) != couldntPlace, let mediaTimeMs = resolution.localMediaTimeMs {
            let totalSeconds = max(0, mediaTimeMs / 1_000)
            return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        }
        return line(for: resolution, paragraph: paragraph)
    }
}
