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
    /// How far after the listener's own note a landing gathers the notes that follow it (#4938): a burst of notes takes one press.
    public static let gatherMs = 30_000

    /// One Margin the landing shows, in turn, as the source reaches it (#4938). A friend's landing has one.
    public struct Note: Equatable, Sendable {
        public let marginId: String
        /// In the landing's `unit`.
        public let position: Int
        /// What the Margin says, nil when it has no words worth showing.
        public let words: String?

        public init(marginId: String, position: Int, words: String?) {
            self.marginId = marginId
            self.position = max(0, position)
            self.words = words
        }
    }

    public let itemId: String
    /// The first note's Margin.
    public let marginId: String
    public let subject: PinnedMarginCard.Subject
    /// The first note's words.
    public let words: String?
    /// The place is a guess (`SharedMarginPlaybackPosition.isApproximate`).
    public let isApproximate: Bool
    /// The stop's place (the first note's), in `unit`.
    public let position: Int
    public let unit: SkimStops.PositionUnit
    /// Never empty, in position-then-id order; the first is the stop the listener landed on.
    public let notes: [Note]
    /// The last place, in `unit`, where the card still shows.
    public let showsUntil: Int
    /// The listener tapped Dismiss: the card is gone, but the landing stays so a Skim press still never meets this stop again.
    public private(set) var isDismissed = false

    public init(
        itemId: String, marginId: String, subject: PinnedMarginCard.Subject, words: String?, isApproximate: Bool,
        position: Int, unit: SkimStops.PositionUnit
    ) {
        let note = Note(marginId: marginId, position: position, words: words)
        self.init(
            itemId: itemId, subject: subject, isApproximate: isApproximate, unit: unit, notes: [note],
            showsUntil: note.position + unit.positions(forMs: Self.showingMs))
    }

    private init(
        itemId: String, subject: PinnedMarginCard.Subject, isApproximate: Bool, unit: SkimStops.PositionUnit, notes: [Note],
        showsUntil: Int
    ) {
        precondition(!notes.isEmpty, "a landing has at least one note")
        self.itemId = itemId
        self.marginId = notes[0].marginId
        self.subject = subject
        self.words = notes[0].words
        self.isApproximate = isApproximate
        self.position = notes[0].position
        self.unit = unit
        self.notes = notes
        self.showsUntil = max(notes[0].position, showsUntil)
    }

    /// The landing for a Skim press (or a list's go-to) that reached the listener's own written `stop` (#4938). It gathers the
    /// own written stops after it in `stops`, up to `gatherMs` past it and never across another stop, so the next press goes past
    /// all of them; the card shows each one's words as the source reaches it. The card goes at the earlier of `showingMs` after the
    /// last note and just before the next stop. Nil unless `stop` is an own written stop whose Margin is in `margins`.
    public init?(own stop: SkimStop, in stops: SkimStops, margins: [Interjection], itemId: String) {
        guard stop.kind == .margin, stop.isOwnWritten, let first = margins.first(where: { $0.id == stop.id }) else { return nil }
        let unit = stops.unit
        func words(_ id: String) -> String? { margins.first { $0.id == id }.flatMap(SilentMarginWords.ownWords) }
        var notes = [Note(marginId: stop.id, position: stop.position, words: SilentMarginWords.ownWords(first))]
        var nextStop: SkimStop?
        if let index = stops.stops.firstIndex(where: { $0.kind == .margin && $0.id == stop.id }) {
            let reach = stop.position + unit.positions(forMs: Self.gatherMs)
            for later in stops.stops[(index + 1)...] {
                if later.kind == .margin, later.isOwnWritten, later.position <= reach {
                    notes.append(Note(marginId: later.id, position: later.position, words: words(later.id)))
                    continue
                }
                nextStop = later
                break
            }
        }
        let last = notes[notes.count - 1].position
        var until = last + unit.positions(forMs: Self.showingMs)
        if let nextStop { until = min(until, nextStop.position - 1) }
        self.init(itemId: itemId, subject: .yours, isApproximate: false, unit: unit, notes: notes, showsUntil: until)
    }

    /// A one-note landing for a go-to on the listener's own written `margin` at `position` (in `unit`), for a note that is not in
    /// the stop list (one dropped on a tie with another stop, #4938).
    public init(own margin: Interjection, position: Int, itemId: String, unit: SkimStops.PositionUnit) {
        self.init(
            itemId: itemId, marginId: margin.id, subject: .yours, words: SilentMarginWords.ownWords(margin), isApproximate: false,
            position: position, unit: unit)
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

    /// The note whose words the card shows with the source at `playhead`: the last one the source has reached, else the first.
    public func shownNote(playhead: Int) -> Note {
        notes.last { $0.position <= playhead } ?? notes[0]
    }

    /// The card, when `isShowing` says it should be, with the first note's words.
    public func card(noun: SourceNoun) -> PinnedMarginCard {
        card(words: words, noun: noun)
    }

    /// The card with the source at `playhead`: the words of the note it has reached (#4938).
    public func card(noun: SourceNoun, playhead: Int) -> PinnedMarginCard {
        card(words: shownNote(playhead: playhead).words, noun: noun)
    }

    private func card(words: String?, noun: SourceNoun) -> PinnedMarginCard {
        PinnedMarginCard(subject: subject, stage: .silentHere(words: words, isApproximate: isApproximate), noun: noun)
    }

    /// Whether the card still shows with the source at `playhead` (in `unit`): from `seekSlackMs` before the first note to
    /// `showsUntil`. For text the spans are converted with the unit's own rate, with no clamp: a lead-in's 30 s minimum would make
    /// the window longer than it is meant to be.
    public func isShowing(playhead: Int) -> Bool {
        playhead >= position - unit.positions(forMs: Self.seekSlackMs) && playhead <= showsUntil
    }

    /// The stop a Skim press goes to, never one of this landing's own notes again (#4934, #4938). `SkimStops.next` and `previous`
    /// are strict about the playhead, so a press just short of the place (the seek landed early) or just past it would find the
    /// stop the listener is already at. The press searches from the playhead as it always did; only when that finds one of this
    /// landing's notes, while the card shows, does it search again: forward from the later of that stop and the last note, back
    /// from the earlier of that stop and the first note, which the strict search then passes. A chapter or Margin between the
    /// playhead and the place is still the answer: the first search finds it. The stop must still be a silent one: a Margin the
    /// listener turned reading back on for is a voiced stop again, with its lead-in, and is met.
    public func skimTarget(
        direction: SkimDirection, playhead: Int, in stops: SkimStops, current: SkimStop? = nil,
        leadInMs: Int = SkimStops.minimumLeadInMs
    ) -> SkimStops.Target? {
        let first = search(direction, stops, playhead, current, leadInMs)
        guard let first, first.stop.isSilent, notes.contains(where: { $0.marginId == first.stop.id }), isShowing(playhead: playhead)
        else { return first }
        let from: Int
        switch direction {
        case .forward: from = max(first.stop.position, notes[notes.count - 1].position)
        case .backward: from = min(first.stop.position, notes[0].position)
        }
        return search(direction, stops, from, current, leadInMs)
    }

    /// The playhead a Skim press passes to `SkimStopRouting.startAction` for a voiced Margin (#4938). A seek to a note can land a
    /// second short of it; from there a press into the next Margin's lead-in would seek back and replay it, where a press from the
    /// note itself plays the Margin now. So while `landing`'s window covers the playhead (in milliseconds, dismissed or not) and it
    /// lies before the target, the press counts from the later of the playhead and the last gathered note before the target: the
    /// press has passed every gathered note (`skimTarget`), and the target's lead-in may start at the last of them.
    public static func startPlayhead(playhead: Int, landing: SilentMarginLanding?, target: SkimStops.Target) -> Int {
        guard let landing, landing.unit == .milliseconds, landing.isShowing(playhead: playhead),
              let passed = landing.notes.last(where: { $0.position < target.stop.position }) else { return playhead }
        return max(playhead, passed.position)
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
