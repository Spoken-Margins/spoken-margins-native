import Foundation

/// The kinds of row the Timeline rail draws (#3734). The app's `TimelineProvenance` maps onto this one-to-one, so the
/// view and the contrast audit read the same palette for every kind. The audit generates its pairs from `allCases`, so a
/// kind added here is measured at once; its label pair is named "<kind> row label" until the audit's name table says
/// otherwise (`TimelineRowPaletteTests` fails on a kind that table doesn't name).
public enum TimelineRowKind: String, CaseIterable, Sendable {
    case source, listeningMap, myMargin, userResponse, sharedMargin, assistantResponse
}

/// The fill, stroke and label colours of a Timeline row. Foundation only, so `PlaybackTimelineListView` and the audit in
/// `ExperienceColorContrast.swift` read the same numbers.
///
/// A row is a plain panel card, and its kind is told by its label, icon, marker and a stronger outline, not by a tint
/// that fought the text on it; the current row is the app's highlighted card, a soft green fill with a 2 pt evergreen
/// outline (#3734). The audit's pairs are generated from these values.
public enum TimelineRowPalette {
    /// A row's fill: a token drawn at `alpha` over whatever is behind the list. `token` names the colour the way the
    /// audit names a tint.
    public struct Fill: Equatable, Sendable {
        public let token: String
        public let color: AppDynamicRGB
        public let alpha: Double
    }

    /// A row's outline.
    public struct Stroke: Equatable, Sendable {
        public let color: AppDynamicRGB
        public let alpha: Double
        public let width: Double
        public let dashed: Bool
    }

    /// The row's fill. Every kind is the panel; the current row is the soft green of the app's highlighted card.
    public static func fill(kind: TimelineRowKind, isCurrent: Bool) -> Fill {
        _ = kind  // The kind is told by the label, icon, marker and outline, not by the fill.
        if isCurrent { return Fill(token: "softGreen", color: AppSemanticColorRGB.softGreen, alpha: 1) }
        return Fill(token: "panel", color: AppSemanticColorRGB.panel, alpha: 1)
    }

    /// The row's outline: the kind's colour at half strength (dashed for the assistant's reply), or an opaque evergreen
    /// 2 pt outline on the current row, which marks a state and so is measured at 3:1.
    public static func stroke(kind: TimelineRowKind, isCurrent: Bool) -> Stroke {
        if isCurrent { return Stroke(color: currentStrokeColor, alpha: 1, width: 2, dashed: false) }
        let dashed = kind == .assistantResponse
        return Stroke(color: labelColor(kind: kind), alpha: dashed ? 0.55 : 0.5, width: 1, dashed: dashed)
    }

    /// The colour of the kind's label, icon and marker.
    public static func labelColor(kind: TimelineRowKind) -> AppDynamicRGB {
        switch kind {
        case .source, .listeningMap: return AppSemanticColorRGB.evergreen
        case .myMargin: return AppSemanticColorRGB.coral
        case .userResponse: return AppSemanticColorRGB.ochreText
        case .sharedMargin, .assistantResponse: return AppSemanticColorRGB.plum
        }
    }

    /// The "Current passage" / "Current chapter" label on the current row.
    public static let currentLabelColor = AppSemanticColorRGB.evergreen

    /// The outline of the current row.
    public static let currentStrokeColor = AppSemanticColorRGB.evergreen
}
