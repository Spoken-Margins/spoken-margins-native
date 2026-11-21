import Foundation

/// What a Timeline row with a picture of its table or figure says and how big it draws it (#3895). The words are
/// here, not in the view, so they are tested on the host and the row, the long-press menu, VoiceOver and the viewer
/// all say the same thing.
public enum TimelineClipPresentation {
    /// The tallest a picture is drawn in a row, in points. It is scaled to fit, never stretched.
    public static let rowMaximumHeight = 220.0

    /// "table" or "figure".
    public static func noun(for kind: StructuredDocument.Float.Kind?) -> String {
        kind == .figure ? "figure" : "table"
    }

    /// The title of the action that opens the picture: "View table" or "View figure".
    public static func viewActionTitle(kind: StructuredDocument.Float.Kind?) -> String {
        "View \(noun(for: kind))"
    }

    /// What VoiceOver reads for the picture: "Table 2, clip of the table, page 7". The label is the one the document
    /// gave the float, or the kind's own word when it had none; the page is named only when it is known.
    public static func spokenLabel(kind: StructuredDocument.Float.Kind?, label: String?, pageIndex: Int?) -> String {
        let noun = noun(for: kind)
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? noun.capitalized
        var parts = [name, "clip of the \(noun)"]
        if let pageIndex, pageIndex >= 0 { parts.append("page \(pageIndex + 1)") }
        return parts.joined(separator: ", ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
