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
/// The values are what the view drew before the audit could see them. A later change moves them, and the audit's
/// pairs and known failures move with them.
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

    /// The row's fill. The current row has one fill whatever its kind.
    public static func fill(kind: TimelineRowKind, isCurrent: Bool) -> Fill {
        if isCurrent { return Fill(token: "evergreen", color: AppSemanticColorRGB.evergreen, alpha: 0.12) }
        switch kind {
        case .source: return Fill(token: "panel", color: AppSemanticColorRGB.panel, alpha: 1)
        case .listeningMap: return Fill(token: "evergreen", color: AppSemanticColorRGB.evergreen, alpha: 0.07)
        case .myMargin: return Fill(token: "coral", color: AppSemanticColorRGB.coral, alpha: 0.08)
        case .userResponse: return Fill(token: "ochre", color: AppSemanticColorRGB.ochre, alpha: 0.08)
        case .sharedMargin, .assistantResponse: return Fill(token: "plum", color: AppSemanticColorRGB.plum, alpha: 0.07)
        }
    }

    /// The row's outline: the kind's colour, dashed for the assistant's reply.
    public static func stroke(kind: TimelineRowKind, isCurrent: Bool) -> Stroke {
        _ = isCurrent  // Today a current row keeps its kind's outline; only its fill changes.
        let dashed = kind == .assistantResponse
        return Stroke(color: labelColor(kind: kind), alpha: dashed ? 0.55 : 0.24, width: 1, dashed: dashed)
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
}
