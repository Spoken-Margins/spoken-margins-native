import Foundation

/// The Margins tab as the control centre for an item with Margins, and the arrival preview that shows the same list
/// (owner's design, 2026-11-17, part of #3216). The views draw what this returns; the ordering, threading, heard state,
/// lead-in excerpt and "words coming" state are decided here so they can be tested on the Mac.
///
/// - Every Margin of the item, in playback order, replies threaded under the Margin they answer
///   (`MarginThreadPresentation`).
/// - Heard means the listener listened to any part of a friend's Margin (`firstHeardAt`); reading or looking at it
///   doesn't count. The listener's own Margins are neither heard nor unheard.
/// - A voice Margin recorded without words carries placeholder words (#3025). It shows as "words coming", never as
///   if the placeholder were the friend's words.
public enum MarginsControlCenter {
    /// The lead-in before a Margin that a row's start control and "Next Margin" jump to (owner, 2026-11-17: 20 s).
    public static let leadInMs = 20_000
    /// "Start from the beginning" on the arrival preview starts at 0:00 (owner, prototype v3).
    public static let startFromBeginningMs = 0

    /// Where a row's start control is shown, which decides its words (owner, prototype v3).
    public enum RowStartContext: String, CaseIterable, Equatable, Sendable {
        /// The arrival preview, before listening starts.
        case arrival
        /// The Margins tab during playback.
        case playback

        /// "Start with this Margin" on arrival, "Jump to this Margin" during playback.
        public var label: String {
            switch self {
            case .arrival: "Start with this Margin"
            case .playback: "Jump to this Margin"
            }
        }
    }

    /// The arrival preview's two start controls (see `startWithUnheardMs` and `startFromBeginningMs`).
    public static let startWithUnheardLabel = "Start with unheard Margins"
    public static let startFromBeginningLabel = "Start from the beginning"

    /// Where "Start with unheard Margins" begins: the lead-in of the first thread holding a friend's Margin the
    /// listener hasn't heard, as in prototype v3. Nil when every Margin is heard (or the thread isn't placed).
    public static func startWithUnheardMs(_ rows: [Row]) -> Int? {
        var root: Row?
        for row in rows {
            if row.depth == 0 { root = row }
            if row.hearing == .unheard { return (root ?? row).startHereMs }
        }
        return nil
    }
    /// How much of the source text before a Margin the row quotes, in characters.
    public static let leadInExcerptCharacters = 110

    public enum Hearing: Equatable, Sendable {
        /// The listener's own Margin.
        case yours
        /// A friend's Margin the listener has listened to some of.
        case heard
        /// A friend's Margin the listener hasn't listened to yet.
        case unheard
    }

    public enum Words: Equatable, Sendable {
        case text(String)
        /// Recorded without words; the words are still to come (placeholder words, or none).
        case coming
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let reference: MarginReference
        public let depth: Int
        public let senderLabel: String
        public let hearing: Hearing
        public let words: Words
        /// The source text just before the Margin, cut to a few words; nil when the Margin carries none.
        public let leadIn: String?
        /// Source time in the listener's copy; nil when the Margin is not placed.
        public let timeMs: Int?
        /// Starred for sharing. Always false for a friend's Margin: only your own can be starred.
        public let isStarred: Bool
        /// Set on a reply whose parent isn't in this Library.
        public let note: String?

        public var id: String {
            switch reference {
            case .local(let id): return "local-\(id)"
            case .imported(let id): return "imported-\(id)"
            }
        }

        public var isYours: Bool { hearing == .yours }

        /// Where the row's start control ("Start with this Margin" / "Jump to this Margin") puts the listener: the lead-in before the Margin, never before the start.
        public var startHereMs: Int? { timeMs.map { max(0, $0 - MarginsControlCenter.leadInMs) } }
    }

    /// The rows for an open item, from the item's own state (its Margins, its friends' layers and their Margins): what the
    /// item screen holds before the Margins list has read the item (#3216).
    public static func rows(item: ItemDetailState) -> [Row] {
        let layers = item.importedCommentaryLayers.filter { $0.deletedAt == nil }
        return rows(
            itemId: item.id, localMargins: item.interjections.filter { $0.status == "active" }, layers: layers,
            importedMargins: layers.flatMap { item.importedCommentaryInterjections[$0.id] ?? [] })
    }

    /// Every active Margin of the item, own and friends', in thread order (see `MarginThreadPresentation.rows`).
    public static func rows(
        itemId: String,
        localMargins: [Interjection],
        layers: [ImportedCommentaryLayer],
        importedMargins: [ImportedCommentaryInterjection]
    ) -> [Row] {
        let thread = MarginThreadPresentation.rows(
            itemId: itemId, localMargins: localMargins, layers: layers, importedMargins: importedMargins)
        let local = Dictionary(localMargins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let imported = Dictionary(importedMargins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return thread.compactMap { row in
            switch row.reference {
            case .local(let id):
                guard let margin = local[id] else { return nil }
                return Row(
                    reference: row.reference, depth: row.depth, senderLabel: row.senderLabel, hearing: .yours,
                    words: words(row.text), leadIn: leadInExcerpt(margin.anchor.anchorBefore),
                    timeMs: row.timeMs, isStarred: margin.isStarredForSharing == true, note: row.note)
            case .imported(let id):
                guard let margin = imported[id] else { return nil }
                return Row(
                    reference: row.reference, depth: row.depth, senderLabel: row.senderLabel,
                    hearing: margin.isNewToListener ? .unheard : .heard,
                    words: words(margin.approvedTranscript), leadIn: leadInExcerpt(margin.anchorEvidence.prefix),
                    timeMs: row.timeMs, isStarred: false, note: row.note)
            }
        }
    }

    /// The words to show: the Margin's own, or "coming" for blank or placeholder words.
    public static func words(_ raw: String?) -> Words {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || SharedMarginPlaceholderWords.matches(text) { return .coming }
        return .text(text)
    }

    /// The last few words of the source text before a Margin, cut at a word and opened with "…" when cut.
    /// Whitespace is collapsed to single spaces. Nil when there is nothing to quote.
    public static func leadInExcerpt(_ prefix: String?, maxCharacters: Int = leadInExcerptCharacters) -> String? {
        let collapsed = (prefix ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxCharacters else { return collapsed }
        let tail = String(collapsed.suffix(maxCharacters))
        // Start at the first whole word, unless the tail is one unbroken word.
        let trimmed = tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? tail
        return "…" + (trimmed.isEmpty ? tail : trimmed)
    }

    /// Something the listener did with a friend's Margin.
    public enum Exposure: Equatable, Sendable {
        /// Its voice (or its words read aloud) played for this long.
        case listened(ms: Int)
        /// Its words were on screen, or expanded in the list.
        case read
        /// Its detail screen was opened.
        case openedDetail
    }

    /// Whether this marks the Margin heard. Listening to any part of it does; reading or looking at it never does
    /// (owner, 2026-11-17).
    public static func marksHeard(_ exposure: Exposure) -> Bool {
        if case .listened(let ms) = exposure { return ms > 0 }
        return false
    }

    /// The Margins tab's Autoplay setting (owner, 2026-11-17; prototype v3). With `.none` ("Off") a tone still marks
    /// each Margin; that is behaviour (`arrival`), not part of the label.
    public enum Autoplay: String, CaseIterable, Equatable, Sendable {
        case unheard
        case all
        case none

        /// The header of the Autoplay menu.
        public static let menuTitle = "Play Margins by themselves"

        public var title: String {
            switch self {
            case .unheard: "Unheard Margins"
            case .all: "All Margins"
            case .none: "Off"
            }
        }
    }

    /// What happens when playback reaches a Margin.
    public enum Arrival: Equatable, Sendable {
        /// The Margin plays by itself.
        case plays
        /// A tone marks it and the episode plays on.
        case tone
    }

    /// What reaching `row` does under `autoplay`. With `.unheard`, only a friend's Margin the listener hasn't heard
    /// plays; a heard one and the listener's own get the tone. (Whether the listener's own Margins should play under
    /// `.unheard` is not decided by the owner's call; this keeps them quiet.)
    public static func arrival(for row: Row, autoplay: Autoplay) -> Arrival {
        switch autoplay {
        case .all: .plays
        case .none: .tone
        case .unheard: row.hearing == .unheard ? .plays : .tone
        }
    }

    /// The Margins that would play by themselves under `autoplay`, in list order.
    public static func autoplaying(_ rows: [Row], autoplay: Autoplay) -> [Row] {
        rows.filter { arrival(for: $0, autoplay: autoplay) == .plays }
    }

    /// The threads in `rows` (a row at depth 0 and every row under it), in list order.
    public static func threads(_ rows: [Row]) -> [[Row]] {
        var threads: [[Row]] = []
        for row in rows {
            if row.depth == 0 || threads.isEmpty { threads.append([row]) } else { threads[threads.count - 1].append(row) }
        }
        return threads
    }

    /// The Margin that plays first when playback lands on `thread` (prototype v3's `firstToPlay`): its first unheard
    /// friend's Margin unless Autoplay is All, otherwise the thread's first Margin.
    public static func firstToPlay(in thread: [Row], autoplay: Autoplay) -> Row? {
        if autoplay != .all, let unheard = thread.first(where: { $0.hearing == .unheard }) { return unheard }
        return thread.first
    }

    /// How many friends' Margins the listener hasn't heard.
    public static func unheardCount(_ rows: [Row]) -> Int { rows.filter { $0.hearing == .unheard }.count }

    /// Opening an item with unheard friends' Margins starts the playback screen on its Margins tab, not Now
    /// (owner, 2026-11-17). Only a friend's Margin the listener hasn't heard counts; a muted or hidden sender's
    /// layer is left out by the caller, as the list leaves it out.
    public static func opensOnMarginsTab(_ rows: [Row]) -> Bool { unheardCount(rows) > 0 }
}

/// "Next Margin" on the Margins tab (owner, 2026-11-17; prototype v3): the time until the next Margin, and where the
/// press goes. It only ever moves forward, and never past the next Margin:
/// - before that Margin's lead-in, it goes to the lead-in (`leadInMs` before the Margin, never before the start);
/// - inside the lead-in, it goes straight into the Margin, not back to the lead-in's start.
/// The app does the seek and the playing; nothing here moves the player.
public struct NextMarginSkip: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        /// Seek forward to the lead-in before the Margin.
        case seekToLeadIn
        /// Already inside the lead-in: go straight into the Margin.
        case playMargin
    }

    /// The Margin the press goes to, in source milliseconds.
    public let marginTimeMs: Int
    /// The start of that Margin's lead-in: `leadInMs` before it, never before the start.
    public let leadInStartMs: Int
    /// From the playhead to the Margin.
    public let msUntilMargin: Int
    public let action: Action
    /// The Margin that plays first in the thread the press lands on (`MarginsControlCenter.firstToPlay`); nil from the
    /// times-only `next(playheadMs:marginTimesMs:)`.
    public let firstToPlay: MarginReference?

    public init(marginTimeMs: Int, leadInStartMs: Int, msUntilMargin: Int, action: Action, firstToPlay: MarginReference? = nil) {
        self.marginTimeMs = marginTimeMs
        self.leadInStartMs = leadInStartMs
        self.msUntilMargin = msUntilMargin
        self.action = action
        self.firstToPlay = firstToPlay
    }

    /// Next Margin on the list (prototype v3's `nextTarget`): it stops only at a thread's first Margin, never at a
    /// reply. Under Unheard it goes to the next thread holding an unheard friend's Margin, or the next thread when none
    /// is ahead. The lead-in and countdown are measured to the thread's first Margin; `firstToPlay` names what plays.
    public static func next(
        playheadMs: Int, rows: [MarginsControlCenter.Row], autoplay: MarginsControlCenter.Autoplay,
        leadInMs: Int = MarginsControlCenter.leadInMs
    ) -> NextMarginSkip? {
        let ahead = MarginsControlCenter.threads(rows).filter { thread in
            guard let time = thread.first?.timeMs else { return false }
            return time > playheadMs
        }
        let preferred = autoplay == .unheard ? ahead.first { $0.contains { $0.hearing == .unheard } } : nil
        guard let thread = preferred ?? ahead.first, let rootTime = thread.first?.timeMs,
              let skip = next(playheadMs: playheadMs, marginTimesMs: [rootTime], leadInMs: leadInMs) else { return nil }
        return NextMarginSkip(
            marginTimeMs: skip.marginTimeMs, leadInStartMs: skip.leadInStartMs, msUntilMargin: skip.msUntilMargin,
            action: skip.action, firstToPlay: MarginsControlCenter.firstToPlay(in: thread, autoplay: autoplay)?.reference)
    }

    /// Where the press puts the playhead: the lead-in's start, or the Margin itself. Never behind the playhead.
    public var destinationMs: Int { action == .playMargin ? marginTimeMs : leadInStartMs }

    /// The first Margin strictly after the playhead, or nil when none is left.
    public static func next(playheadMs: Int, marginTimesMs: [Int], leadInMs: Int = MarginsControlCenter.leadInMs) -> NextMarginSkip? {
        let target = marginTimesMs
            .filter { $0 >= 0 }
            .sorted()
            .first { $0 > playheadMs }
        guard let target else { return nil }
        let leadInStart = max(0, target - leadInMs)
        return NextMarginSkip(
            marginTimeMs: target, leadInStartMs: leadInStart, msUntilMargin: target - playheadMs,
            action: playheadMs >= leadInStart ? .playMargin : .seekToLeadIn)
    }

    /// The floating "Next Margin" pill's countdown: an `m:ss` clock such as "5:28", rounded up
    /// (`PinnedMarginCard.countdown`).
    public var countdown: String { PinnedMarginCard.countdown(msUntilMargin) }
}
