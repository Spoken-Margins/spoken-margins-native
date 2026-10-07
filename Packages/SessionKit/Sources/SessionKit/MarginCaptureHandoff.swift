import Foundation

/// Add Margin while a Margin is playing (#866). The Margin's voice stops and recording starts at once, anchored
/// where the playing Margin sits in the source. The source paused a progress tick after that place (or wherever
/// the listener was when they opened it from a list), so it moves back to the Margin before the recorder samples it.
public struct MarginCaptureHandoff: Sendable, Equatable {
    public enum Place: Sendable, Equatable {
        case media(ms: Int)
        case text(charOffset: Int)
    }

    public enum SourceMove: Sendable, Equatable {
        case stay
        case seekMedia(ms: Int)
        case seekText(charOffset: Int)
    }

    /// The item the playing Margin belongs to.
    public let itemId: String?
    /// Where the playing Margin sits in that item, when the app knows.
    public let place: Place?

    public init(itemId: String?, place: Place?) {
        self.itemId = itemId
        self.place = place
    }

    /// A shared Margin playing on its own, at its place in this listener's copy.
    public init(sharedMargin: ImportedCommentaryInterjection, itemId: String?) {
        let resolution = sharedMargin.resolution
        self.init(
            itemId: itemId,
            place: resolution.localMediaTimeMs.map { Place.media(ms: $0) }
                ?? resolution.localStartChar.map { Place.text(charOffset: $0) }
        )
    }

    /// One of the listener's own Margins playing from its detail sheet: the place it was recorded at in its item.
    /// A conversation turn's place is relative to that turn, so it isn't handed off.
    public init(localMargin: Interjection) {
        let anchor = localMargin.anchor
        let place: Place?
        switch anchor.anchorType {
        case .media, .transcript: place = anchor.mediaTimeMs.map { Place.media(ms: $0) }
        case .text: place = .text(charOffset: anchor.startChar)
        case .turn: place = nil
        }
        self.init(itemId: localMargin.itemId, place: place)
    }

    /// The Margin a Margin moment is playing inline, if any.
    public init(moment: MarginMomentSequence) {
        self.init(itemId: moment.itemId, place: moment.playing.map { Place.media(ms: $0.mediaTimeMs) })
    }

    /// Where the source must go so the new Margin is anchored at the playing Margin. A Margin from another item,
    /// or one without a place, leaves the source where it is. So does a source that can't show the place: a
    /// conversation turn has no article or media place of its own, and live speech has no media clock.
    public func sourceMove(from snapshot: SessionSnapshot) -> SourceMove {
        guard let itemId, itemId == snapshot.itemId, let place else { return .stay }
        let source = snapshot.targetType
        if source == TargetType.assistantTurnTTS.rawValue || source == TargetType.summaryTurnTTS.rawValue { return .stay }
        switch place {
        case .media(let ms):
            if source == TargetType.itemTextTTS.rawValue { return .stay }
            return snapshot.currentMediaTimeMs == ms ? .stay : .seekMedia(ms: ms)
        case .text(let charOffset):
            return snapshot.currentTextStart == charOffset ? .stay : .seekText(charOffset: charOffset)
        }
    }
}
