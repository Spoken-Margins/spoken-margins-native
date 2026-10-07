import Foundation

/// Add Margin while a Margin is playing (#866). The Margin's voice stops and recording starts at once, anchored
/// where the playing Margin sits in the source. The source paused a progress tick after that place (or wherever
/// the listener was when they opened it from a list), so it moves back to the Margin before the recorder samples it.
public struct MarginCaptureHandoff: Sendable, Equatable {
    public enum Place: Sendable, Equatable {
        case media(ms: Int)
        case text(charOffset: Int)
        /// A Margin recorded on an article's prepared narration: the media time it was heard at, and the article text
        /// offset that time sits on. The text offset is what places it when the article reads aloud as live speech.
        case narration(ms: Int, charOffset: Int)
        /// A Margin recorded on one conversation turn, at an offset in that turn's own text.
        case turn(id: String, charOffset: Int)
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

    /// One of the listener's own Margins playing from its detail sheet: the place it was recorded at. A conversation
    /// turn's place is relative to that turn, so it carries the turn's identity and only moves that turn.
    public init(localMargin: Interjection) {
        let anchor = localMargin.anchor
        let place: Place?
        switch anchor.anchorType {
        case .media: place = anchor.mediaTimeMs.map { Place.media(ms: $0) }
        case .transcript:
            // On prepared narration the anchor's text range is the article's own text, so it still places the Margin
            // when the article later reads aloud as live speech. On a podcast it is a transcript position, which no
            // text source reads, so it is never used there.
            place = anchor.mediaTimeMs.map { Place.narration(ms: $0, charOffset: anchor.startChar) }
        case .text: place = .text(charOffset: anchor.startChar)
        case .turn:
            switch localMargin.targetType {
            case .assistantTurn, .summaryTurn: place = .turn(id: localMargin.targetId, charOffset: anchor.startChar)
            case .item: place = nil
            }
        }
        self.init(itemId: localMargin.itemId, place: place)
    }

    /// The Margin a Margin moment is playing inline, if any.
    public init(moment: MarginMomentSequence) {
        self.init(itemId: moment.itemId, place: moment.playing.map { Place.media(ms: $0.mediaTimeMs) })
    }

    /// Where the source must go so the new Margin is anchored at the playing Margin. A Margin from another item,
    /// or one without a place, leaves the source where it is. So does a source that can't show the place: a
    /// conversation turn has no article or media place of its own, a turn Margin only moves its own turn, and live
    /// speech has no media clock (a Margin recorded on narration then goes by its text offset).
    public func sourceMove(from snapshot: SessionSnapshot) -> SourceMove {
        guard let itemId, itemId == snapshot.itemId, let place else { return .stay }
        let source = snapshot.targetType
        let onTurn = source == TargetType.assistantTurnTTS.rawValue || source == TargetType.summaryTurnTTS.rawValue
        let onLiveSpeech = source == TargetType.itemTextTTS.rawValue
        func text(_ charOffset: Int) -> SourceMove {
            snapshot.currentTextStart == charOffset ? .stay : .seekText(charOffset: charOffset)
        }
        func media(_ ms: Int) -> SourceMove {
            snapshot.currentMediaTimeMs == ms ? .stay : .seekMedia(ms: ms)
        }
        switch place {
        case .turn(let turnId, let charOffset):
            return onTurn && snapshot.targetId == turnId ? text(charOffset) : .stay
        case .media(let ms):
            return onTurn || onLiveSpeech ? .stay : media(ms)
        case .narration(let ms, let charOffset):
            if onTurn { return .stay }
            return onLiveSpeech ? text(charOffset) : media(ms)
        case .text(let charOffset):
            return onTurn ? .stay : text(charOffset)
        }
    }
}
