import Foundation

/// What the screens that show one of the listener's own Margins say and offer when the Margin has no place on its item
/// (#4233, PR 3b of the Design). A Margin moved from a live session with no playback position stored has
/// `Interjection.hasPlace == false`: its percent and anchor are zeros that mean nothing, so a screen that read them would
/// say "0%" or "0:00", offer to go to a moment that isn't there, or offer to share a Margin a packet leaves out.
///
/// One answer for the Margin details, the item screen and the position badges, so no screen decides it alone and a
/// placed Margin reads exactly as it always did.
public enum MarginPlacePresentation {
    /// The details' "Position" line for a Margin with no place.
    public static let detailPosition = "No place saved"

    /// Where a Margin with no place sorts on the Timeline and in Now Playing's list (PR 3c): after every placed entry.
    /// Every placed position is a percent clamped to 0...100, a friend's Margin with no evidence sorts at 100, and a
    /// reflection at its source Margins' place, so 101 is past all of them and never drawn as a number.
    public static let timelineSortPosition = 101

    /// The Timeline card's corner for a Margin with no place: "No place", never a percent made from its stored zeros.
    public static let timelineLabel = TimelinePositionLabel.Label(
        corner: MarginRowWording.noPlace, spoken: MarginRowWording.noPlace, chapterDetail: MarginRowWording.noPlace)

    /// The Timeline card's detail line for one of the listener's own Margins: "Captured at 40%", or "No place".
    public static func timelineDetail(for margin: Interjection, position: Int) -> String {
        margin.hasPlace ? "Captured at \(position)%" : MarginRowWording.noPlace
    }

    /// Whether a row in Now Playing's lists (Nearby Margins, Margins) offers Play. A Margin with no place has no moment to
    /// play, so Play is dimmed and its words still open its details. Same answer as a tap on its row (`MarginRowTap`).
    public static func offersPlay(_ margin: Interjection) -> Bool {
        MarginRowTap.action(for: margin) == .playMoment
    }

    /// The line under a Margin on the item screen: "At 40%", or "No place" for a Margin with no place (Design 2.8).
    public static func itemScreenLine(for margin: Interjection) -> String {
        margin.hasPlace ? "At \(margin.roughPercent)%" : MarginRowWording.noPlace
    }

    /// A moved Margin's origin, for the details (Design 2.8): `Moved from “Quick session”`, with
    /// ` · was about page 120` when the live session said where the Margin was. Nil for a Margin that was never moved.
    /// The label is the listener's own words about the outside source; it is shown and never used as a place.
    public static func movedFromLine(for margin: Interjection) -> String? {
        guard let origin = margin.movedOrigin else { return nil }
        let title = origin.fromLiveSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = "Moved from “\(title)”"
        if let label = origin.sessionPlaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            line += " · was \(label)"
        }
        return line
    }

    /// "Go to this moment in the source" is offered only for a Margin with a moment to go to. Same answer as a tap on its
    /// row (`MarginRowTap`).
    public static func offersGoToMoment(_ margin: Interjection) -> Bool {
        MarginRowTap.action(for: margin) == .playMoment
    }

    /// "Share this Margin" is offered only for a Margin a packet can carry: one the Share sheet would list and that has
    /// a place. PR 4 makes the sheet itself leave unplaced Margins out; until then the details don't offer a share
    /// that would send one.
    public static func offersShare(_ margin: Interjection) -> Bool {
        margin.hasPlace && ItemShareSessionSelection.isShareable(margin)
    }
}
