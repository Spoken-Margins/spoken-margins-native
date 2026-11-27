import Foundation

/// Where the listener just went to a friend's Margin that is never spoken, and for how long the pinned card says so
/// (#4934). Skim or a list's Go-to moves the source to the Margin's place and plays on; nothing is read aloud, so the card
/// (`PinnedMarginCard.Stage.silentHere`) is the only sign of what is there.
///
/// Pure: the app keeps one value and passes the source's place. Whether the card still shows is a read of that place, not
/// a timer, so it is right at any playback speed and for a listener who pauses.
public struct SilentMarginLanding: Equatable, Sendable {
    /// The seek to a place can land a little short of it.
    public static let seekSlackMs = 2_000
    /// How far past the place the card stays.
    public static let showingMs = 30_000

    public let itemId: String
    public let marginId: String
    public let subject: PinnedMarginCard.Subject
    /// What the Margin says, nil when it has no words worth showing.
    public let words: String?
    /// The place is a guess (`SharedMarginPlaybackPosition.isApproximate`).
    public let isApproximate: Bool
    /// The stop's place, in `unit`.
    public let position: Int
    public let unit: SkimStops.PositionUnit
    /// The listener tapped Dismiss: the card is gone, but the landing stays so a Skim press still never meets this stop again.
    public private(set) var isDismissed = false

    public init(
        itemId: String, marginId: String, subject: PinnedMarginCard.Subject, words: String?, isApproximate: Bool,
        position: Int, unit: SkimStops.PositionUnit
    ) {
        self.itemId = itemId
        self.marginId = marginId
        self.subject = subject
        self.words = words
        self.isApproximate = isApproximate
        self.position = max(0, position)
        self.unit = unit
    }

    /// The landing for going to a friend's `margin` on `itemId`, from its place (`SharedMarginReplyPlace`): a time in an episode
    /// (in ms; an approximate one says so on the card), or a passage of text (a character offset, in `textUnit`). Nil when
    /// the Margin has no place to go to. The words are the Margin's own, nil when it has none worth showing.
    public init?(
        going margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, itemId: String,
        textUnit: SkimStops.PositionUnit
    ) {
        guard let place = SharedMarginReplyPlace(margin) else { return nil }
        switch place {
        case .media(let timeMs):
            self.init(margin, in: layer, itemId: itemId, position: timeMs, unit: .milliseconds)
        case .text(let charOffset):
            self.init(margin, in: layer, itemId: itemId, position: charOffset, unit: textUnit)
        }
    }

    /// The landing for a Skim press that went to the silent `stop` (#4934). It keeps the stop's own place and unit, not the place
    /// a list's go-to would find for the same Margin, so `skimTarget` can tell the next press this stop is behind or ahead of
    /// it. Nil when `stop` is not a silent Margin stop, or is not this Margin's.
    public init?(
        skipping stop: SkimStop, margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, itemId: String,
        unit: SkimStops.PositionUnit
    ) {
        guard stop.kind == .margin, stop.isSilent, stop.id == margin.id else { return nil }
        self.init(margin, in: layer, itemId: itemId, position: stop.position, unit: unit)
    }

    private init(
        _ margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, itemId: String, position: Int,
        unit: SkimStops.PositionUnit
    ) {
        let words = margin.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let approximate: Bool
        switch unit {
        case .milliseconds: approximate = SharedMarginPlaybackPosition(margin)?.isApproximate ?? true
        case .characters: approximate = false
        }
        self.init(
            itemId: itemId, marginId: margin.id,
            subject: .friend(SharedPacketArrival.senderName(layer.displayLabel)),
            words: words.isEmpty ? nil : words, isApproximate: approximate, position: position, unit: unit)
    }

    /// This landing after Dismiss: no card, same place for `skimTarget`.
    public func dismissed() -> SilentMarginLanding {
        var copy = self
        copy.isDismissed = true
        return copy
    }

    /// The card, when `isShowing` says it should be.
    public func card(noun: SourceNoun) -> PinnedMarginCard {
        PinnedMarginCard(subject: subject, stage: .silentHere(words: words, isApproximate: isApproximate), noun: noun)
    }

    /// Whether the card still shows with the source at `playhead` (in `unit`): from `seekSlackMs` before the place to
    /// `showingMs` after it. For text the two spans are converted with the unit's own rate, with no clamp: a lead-in's 30 s
    /// minimum would make the window longer than it is meant to be.
    public func isShowing(playhead: Int) -> Bool {
        playhead >= position - unit.positions(forMs: Self.seekSlackMs)
            && playhead <= position + unit.positions(forMs: Self.showingMs)
    }

    /// The stop a Skim press goes to, never this landing's own stop again (#4934). `SkimStops.next` and `previous` are strict
    /// about the playhead, so a press just short of the place (the seek landed early) or just past it would find the stop
    /// the listener is already at. The press searches from the playhead as it always did; only when that finds this
    /// landing's own stop, while the card shows, does it search again from the place, which the strict search then passes.
    /// A chapter or Margin between the playhead and the place is still the answer: the first search finds it. The stop must still
    /// be a silent one: a Margin the listener turned reading back on for is a voiced stop again, with its lead-in, and is met.
    public func skimTarget(
        direction: SkimDirection, playhead: Int, in stops: SkimStops, current: SkimStop? = nil,
        leadInMs: Int = SkimStops.minimumLeadInMs
    ) -> SkimStops.Target? {
        let first = search(direction, stops, playhead, current, leadInMs)
        guard let first, first.stop.isSilent, first.stop.id == marginId, isShowing(playhead: playhead) else { return first }
        return search(direction, stops, position, current, leadInMs)
    }

    private func search(
        _ direction: SkimDirection, _ stops: SkimStops, _ playhead: Int, _ current: SkimStop?, _ leadInMs: Int
    ) -> SkimStops.Target? {
        switch direction {
        case .backward: stops.previous(playhead: playhead, current: current, leadInMs: leadInMs)
        case .forward: stops.next(playhead: playhead, current: current, leadInMs: leadInMs)
        }
    }
}
