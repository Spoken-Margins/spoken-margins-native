import Foundation

/// How the Margins tab and the arrival preview lay out `MarginsControlCenter.rows` (owner's prototype v3, 2026-11-17,
/// part of #3216): threads, their indent, who a deep reply answers, the filter, and which way a row's jump goes. The
/// rules about heard, words and lead-ins stay in `MarginsControlCenter`; this only arranges its rows for the views.
public enum MarginsTabList {
    /// One row as the list draws it.
    public struct Entry: Equatable, Sendable, Identifiable {
        public let row: MarginsControlCenter.Row
        /// A reply. Replies are indented once, however deep they go, so a long chain never squeezes.
        public var isReply: Bool { row.depth > 0 }
        /// Who a reply below the first level answers ("to Sam"). Nil for a thread's first Margin and its direct replies,
        /// whose place under the parent already says it.
        public let replyTo: String?
        public var id: String { row.id }
    }

    /// One thread: its first Margin, then every reply under it in order.
    public struct Thread: Equatable, Sendable, Identifiable {
        public let entries: [Entry]
        public var root: Entry { entries[0] }
        public var id: String { root.id }
    }

    /// Splits rows (already in thread order) into threads, and names the Margin each deep reply answers.
    public static func threads(_ rows: [MarginsControlCenter.Row]) -> [Thread] {
        var threads: [[Entry]] = []
        // The nearest row seen at each depth: a reply's parent is the last row one level up.
        var lastAtDepth: [Int: MarginsControlCenter.Row] = [:]
        for row in rows {
            if row.depth == 0 || threads.isEmpty {
                threads.append([])
                lastAtDepth.removeAll()
            }
            let parent = row.depth > 0 ? lastAtDepth[row.depth - 1] : nil
            let replyTo = row.depth >= 2 ? parent?.shownName : nil
            threads[threads.count - 1].append(Entry(row: row, replyTo: replyTo))
            lastAtDepth[row.depth] = row
            lastAtDepth = lastAtDepth.filter { $0.key <= row.depth }
        }
        return threads.map(Thread.init(entries:))
    }

    /// The threads a filter keeps: Mine keeps a thread holding any of your Margins, Shared one holding any friend's.
    /// A thread is kept or dropped whole, so a reply is never shown without what it answers.
    public static func filter(_ threads: [Thread], _ filter: PlaybackMarginsList.Filter) -> [Thread] {
        switch filter {
        case .all: threads
        case .mine: threads.filter { $0.entries.contains { $0.row.isYours } }
        case .shared: threads.filter { $0.entries.contains { !$0.row.isYours } }
        }
    }

    /// Which way "Jump to this Margin" goes from the playhead: its skip icon points forward or back.
    public enum JumpDirection: Equatable, Sendable {
        case forward
        case backward
    }

    /// Forward when the row's jump target (its lead-in) is ahead of the playhead, back otherwise. An unplaced Margin
    /// has nowhere to go and reads as forward.
    public static func jumpDirection(_ row: MarginsControlCenter.Row, playheadMs: Int) -> JumpDirection {
        guard let target = row.startHereMs else { return .forward }
        return target > playheadMs ? .forward : .backward
    }
}

/// The arrival preview (owner's prototype v3): its own screen before listening starts, a welcome line over the same
/// list as the Margins tab, and the two start choices pinned at the bottom.
public enum MarginsArrivalPreview {
    /// Shown when an item has friends' Margins the listener hasn't heard and they haven't started it yet: no place to
    /// carry on from and no finished listen. A listener with a place keeps Continue, and the item opens on the playback
    /// screen's Margins tab instead: the preview only offers 0:00 or the Margins.
    public static func shows(_ rows: [MarginsControlCenter.Row], resumePlace: Position?, hasFinishedSession: Bool) -> Bool {
        let hasPlace = resumePlace.map { ($0.mediaTimeMs ?? 0) > 0 || $0.charOffset > 0 } ?? false
        return MarginsControlCenter.opensOnMarginsTab(rows) && !hasFinishedSession && !hasPlace
    }

    /// "Sam and Priya left 5 Margins": every friend with an unheard Margin, in list order, and how many are unheard.
    public static func welcomeLine(_ rows: [MarginsControlCenter.Row]) -> String {
        let unheard = rows.filter { $0.hearing == .unheard }
        var names: [String] = []
        for row in unheard where !names.contains(row.shownName) { names.append(row.shownName) }
        let who: String
        switch names.count {
        case 0: who = MarginsControlCenter.Row.unnamedFriend
        case 1: who = names[0]
        default: who = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let count = unheard.count
        return "\(who) left \(count) \(count == 1 ? "Margin" : "Margins")"
    }

    /// The line under the welcome.
    public static let explanation = "A Margin is a note left at a moment in this episode. You'll hear each one there."
}

/// The Margins tab's Autoplay menu wired through the existing auto-play path. Today's setting is per layer: `.guided`
/// plays a friend's Margin by itself, `.companion` sounds a tone. "Unheard" is `.guided` that treats a Margin the
/// listener already heard as `.companion`; "All" is `.guided` as before; "Off" is `.companion`. No new reveal mode is
/// stored, so a database written by this build still opens in the last shipped build.
public enum MarginsAutoplaySetting {
    /// The menu's value from the layers' auto-play state and the listener's "include heard" preference.
    public static func current(autoPlayOn: Bool, includesHeard: Bool) -> MarginsControlCenter.Autoplay {
        guard autoPlayOn else { return .none }
        return includesHeard ? .all : .unheard
    }

    /// What choosing `autoplay` writes: whether the layers auto-play, and whether heard Margins play too.
    public static func writes(_ autoplay: MarginsControlCenter.Autoplay) -> (autoPlayOn: Bool, includesHeard: Bool) {
        switch autoplay {
        case .unheard: (true, false)
        case .all: (true, true)
        case .none: (false, false)
        }
    }

    /// The reveal mode the prompt acts on for one Margin. Only a heard Margin under "Unheard" changes: it gets the tone.
    public static func revealMode(
        _ layerMode: ImportedCommentaryRevealMode?, heard: Bool, includesHeard: Bool
    ) -> ImportedCommentaryRevealMode? {
        if layerMode == .guided, heard, !includesHeard { return .companion }
        return layerMode
    }
}

extension MarginsControlCenter.Row {
    /// What a friend's row says when the file names nobody.
    public static let unnamedFriend = "A friend"

    /// The name the list shows: your own label as it is, a friend's through `SharedPacketArrival.senderName`, so an
    /// unsigned packet's stand-in reads "A friend" and never "Unsigned sender".
    public var shownName: String {
        isYours ? senderLabel : SharedPacketArrival.senderName(senderLabel) ?? Self.unnamedFriend
    }
}

extension MarginsControlCenter.Autoplay {
    /// The menu button's short word: "Autoplay Unheard".
    public var shortTitle: String {
        switch self {
        case .unheard: "Unheard"
        case .all: "All"
        case .none: "Off"
        }
    }
}
