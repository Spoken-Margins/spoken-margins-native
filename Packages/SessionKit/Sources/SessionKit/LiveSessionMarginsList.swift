import Foundation

/// A live session's Margins in the order and with the labels the live screen shows (#3491): the same ordering the
/// playback screen's Margins list uses (`PlaybackMarginsList`), so the two screens agree.
public enum LiveSessionMarginsList {
    /// The session's Margins in source order. A Margin's position is its place in the source when the session can
    /// say one (the clock for a session with one, the located page, percent or chapter for a session placed by
    /// place), else none, and then it sorts by when it was taken. Ties go older first.
    public static func rows(for session: LiveSession, anchors: [LiveSessionPositionMap.Anchor] = []) -> [PlaybackMarginsList.Row] {
        let candidates = session.margins.map { margin in
            PlaybackMarginsList.Row(
                id: margin.id, origin: .own,
                position: position(of: margin, in: session, anchors: anchors),
                isApproximate: true, createdAt: margin.markedAt
            )
        }
        return PlaybackMarginsList.ordered(candidates, filter: .all)
    }

    private static func position(of margin: LiveSessionMargin, in session: LiveSession, anchors: [LiveSessionPositionMap.Anchor]) -> PlaybackMarginsList.Position? {
        if session.usesPlaces {
            guard let located = LiveSessionPlaceMap.located(margin, in: session) else { return nil }
            return .charOffset(Int(located.place.value.rounded()))
        }
        guard let position = LiveSessionPositionMap.position(of: margin, in: session, anchors: anchors) else { return nil }
        return .mediaTimeMs(position.ms)
    }

    /// Where a Margin is, in the unit the session uses: a page, percent or chapter is never shown as a time (#2707).
    public static func positionLabel(for margin: LiveSessionMargin, in session: LiveSession) -> String {
        var text: String
        if let label = LiveSessionPlaceMap.label(for: margin, in: session) {
            text = label
        } else if session.usesPlaces {
            text = "\(LiveSessionPositionMap.clock(margin.sessionOffsetMs)) in"
        } else {
            text = LiveSessionPositionMap.position(of: margin, in: session).map { $0.isListenerSet ? "you set \(LiveSessionPositionMap.clock($0.ms))" : $0.label }
                ?? "\(LiveSessionPositionMap.clock(margin.sessionOffsetMs)) in"
        }
        // A place in another unit than the session's is kept beside it, not converted.
        if let place = margin.place, !text.hasSuffix(place.label) { text += " · \(place.label)" }
        return text
    }
}
