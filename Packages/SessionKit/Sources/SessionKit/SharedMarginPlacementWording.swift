import Foundation

/// #1974: where a shared Margin sits, in words a recipient can tell apart. One function so the Margins tab,
/// the Timeline and the import sheet say the same thing, and none of them prints a character offset or an
/// enum name.
public enum SharedMarginPlacementWording {
    public static let placed = "Placed here"
    public static let approximate = "Placed roughly here"
    public static let confirmed = "Placed where you confirmed"
    public static let couldntPlace = "Couldn’t place this one. Tap to listen anyway."

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
}
