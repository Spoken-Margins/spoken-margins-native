import Foundation

/// #1974: where a shared Margin sits, in words a recipient can tell apart. One function so the Margins tab,
/// the Timeline and the import sheet say the same thing, and none of them prints a character offset or an
/// enum name.
public enum SharedMarginPlacementWording {
    public static let placed = "Placed here"
    public static let approximate = "Placed roughly here"
    public static let confirmed = "Placed where you confirmed"
    public static let couldntPlace = "Couldn't place this one. Tap to listen anyway."

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
