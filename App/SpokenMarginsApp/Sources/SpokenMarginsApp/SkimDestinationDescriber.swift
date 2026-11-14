import Foundation
import SessionKit

/// Resolves where a Skim press would land into the words VoiceOver reads for the chapter row's arrows (#3986).
///
/// The words themselves are `SkimDestinationSpeech`, a pure function in SessionKit. What lives here is the lookup that
/// needs the app's item detail: a stop's id becomes a chapter title, the listener's own Margin, or a friend's. It takes
/// plain values rather than the model, so a test builds one without an engine or a store, and it keeps no state.
struct SkimDestinationDescriber {
    /// A text item read aloud: stops and the playhead are character offsets, said as a percentage of `textLength`.
    var isText: Bool
    var textLength: Int
    /// The item's chapters in the item's own unit, in playback order: text chapters by character, media chapters (or
    /// the Listening Map's scenes when the item has none) by millisecond.
    var chapters: [(id: String, title: String, position: Int)]
    var ownMarginIds: Set<String>
    /// A friend's Margin id to the label its packet carries (nil when the file names nobody).
    var friendLabels: [String: String?]
    /// The playhead, in the same unit as the stops; nil when the item isn't playing.
    var playhead: Int?

    init(
        isText: Bool, textLength: Int,
        chapters: [(id: String, title: String, position: Int)],
        ownMarginIds: Set<String>, friendLabels: [String: String?], playhead: Int?
    ) {
        self.isText = isText
        self.textLength = textLength
        self.chapters = chapters.sorted { $0.position < $1.position }
        self.ownMarginIds = ownMarginIds
        self.friendLabels = friendLabels
        self.playhead = playhead
    }

    /// A position said in the item's own unit, or nil when it isn't known ("65 percent", "1 hour, 7 minutes, 30 seconds").
    func spokenPosition(_ position: Int?) -> String? {
        guard let position else { return nil }
        if isText {
            return PlaybackPositionText.percent(position: position, length: textLength).map(PlaybackPositionText.spoken(percent:))
        }
        return PlaybackPositionText.spoken(ms: position)
    }

    /// The chapter's title, or "Chapter N" when it has none; nil when `id` is no chapter of this item.
    func chapterTitle(id: String) -> String? {
        guard let index = chapters.firstIndex(where: { $0.id == id }) else { return nil }
        return SkimDestinationSpeech.chapterTitle(chapters[index].title, index: index)
    }

    /// The chapter or scene `position` falls in (the last that has started by then), for a summary that lands there. A
    /// summary lands at a Listening Map scene start, which is usually inside one of an item's own chapters. Nil before
    /// the first one starts.
    func chapterTitle(containing position: Int) -> String? {
        guard let index = chapters.lastIndex(where: { $0.position <= position }) else { return nil }
        return SkimDestinationSpeech.chapterTitle(chapters[index].title, index: index)
    }

    /// The chapter the playhead is in: the last one that has started. Skim back to its start is "Start of this chapter".
    private var currentChapterId: String? {
        guard let playhead else { return nil }
        return chapters.last(where: { $0.position <= playhead })?.id
    }

    /// Where a press goes. `summaryDestination` is where the scene summary lands, in the item's unit, for a choice that
    /// plays one first.
    func destination(
        of choice: SkimStopRouting.Choice?, direction: SkimDirection, summaryDestination: Int?
    ) -> SkimDestinationSpeech.Destination {
        switch choice {
        case nil, .unavailable?: return .none
        case .summary?:
            let title = summaryDestination.flatMap { chapterTitle(containing: $0) } ?? ""
            return .summaryFirst(title: title)
        case .stop(let target)?:
            let stop = target.stop
            switch stop.kind {
            case .chapter:
                if direction == .backward, stop.id == currentChapterId { return .chapterStart }
                return .chapter(title: chapterTitle(id: stop.id) ?? "")
            case .margin:
                if ownMarginIds.contains(stop.id) { return .ownMargin }
                return .friendMargin(name: friendLabels[stop.id] ?? nil)
            }
        }
    }

    /// The speech for one Skim arrow that can be pressed or is dimmed.
    func speech(
        direction: SkimDirection, choice: SkimStopRouting.Choice?, summaryDestination: Int?
    ) -> SkimDestinationSpeech.Speech {
        let spoken: SkimDestinationSpeech.Direction = direction == .forward ? .forward : .backward
        let destination = destination(of: choice, direction: direction, summaryDestination: summaryDestination)
        let position: Int?
        switch choice {
        case .stop(let target)?: position = target.stop.position
        case .summary?: position = summaryDestination
        case .unavailable?, nil: position = nil
        }
        return SkimDestinationSpeech.skim(spoken, to: destination, position: spokenPosition(position))
    }

    /// While a scene summary plays, a press ends it at the place it lands: the chapter or scene it falls in.
    func landingSpeech(direction: SkimDirection, at position: Int) -> SkimDestinationSpeech.Speech {
        SkimDestinationSpeech.skim(
            direction == .forward ? .forward : .backward,
            to: .chapter(title: chapterTitle(containing: position) ?? ""), position: spokenPosition(position))
    }

    /// Next chapter, plain or standing in for Skim. `chapterId` and `start` are the next chapter's id and start in the item's unit.
    func nextChapterSpeech(
        standingInFor reason: SkimUnavailableReason?, chapterId: String?, start: Int?, inSkimSlot: Bool
    ) -> SkimDestinationSpeech.Speech {
        let title = chapterId.flatMap { chapterTitle(id: $0) } ?? ""
        let position = spokenPosition(start)
        return inSkimSlot
            ? SkimDestinationSpeech.nextChapterInSkimSlot(reason: reason, title: title, position: position)
            : SkimDestinationSpeech.nextChapter(title: title, position: position)
    }
}
