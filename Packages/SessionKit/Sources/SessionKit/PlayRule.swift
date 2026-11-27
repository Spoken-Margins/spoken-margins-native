import Foundation

/// What the big Play / Continue button does on an item, decided once (#4099). It is the one rule behind
/// `Gate1AppModel.continueListening`, `Gate1AppModel.startItem` and the item screen's Play: where the episode starts,
/// and whether a friend's Margins the listener is already past are asked about first.
///
/// It reads state and writes none. The owner's calls it follows: a friend's Margin still ahead of the place plays in
/// place as the episode reaches it, with no question (#3059); a Margin behind the place is asked about and never
/// skipped silently (#474, #4097); a question the listener already turned down isn't asked again until another Margin
/// arrives (`NewMarginsOfferMemory`).
public enum PlayRule {
    /// Which screen the listener tapped Play on. They differ today, and the difference is one line here.
    public enum Surface: Equatable, Sendable {
        /// The Library row's Continue. Asks about Margins behind the place.
        case libraryRow
        /// The item screen's Play, beside "Skip to <friend>'s Margins". It never shows the question: with Margins
        /// behind the saved place its pinned buttons are the two choices instead (`ItemListeningChoices`, #4125), and
        /// otherwise Play starts the episode in place (#3219), friend Margins ahead playing as it reaches them.
        case itemScreen

        var asksAboutMarginsBehind: Bool { self == .libraryRow }
    }

    /// What is playing now, when something is.
    public struct NowPlaying: Equatable, Sendable {
        public let itemId: String
        /// The playhead in the media, or nil when the player doesn't report one yet.
        public let mediaTimeMs: Int?
        /// Where text read aloud stands, in characters (`snapshot.currentTextStart`), for an article whose session has
        /// no media time (#5409). Nil for media.
        public let textOffset: Int?
        public init(itemId: String, mediaTimeMs: Int?, textOffset: Int? = nil) {
            self.itemId = itemId
            self.mediaTimeMs = mediaTimeMs
            self.textOffset = textOffset
        }
    }

    /// The item the app holds open, with its sessions. Opening an item loads them; the Library holds only a row.
    public struct OpenItem: Equatable, Sendable {
        public let id: String
        /// The item's sessions as stored, every old one. `PlayRule` filters them itself with `addedAgainAt`, so a surface
        /// can't pass the listening that ended before the listener added the item again (#4183).
        public let sessions: [Session]
        /// When the listener last added the item again, nil for an item never added again.
        public let addedAgainAt: Date?
        public init(id: String, sessions: [Session], addedAgainAt: Date?) {
            self.id = id
            self.sessions = sessions
            self.addedAgainAt = addedAgainAt
        }
    }

    /// Where the episode starts when Play goes ahead.
    public enum Start: Equatable, Sendable {
        /// A new session at the start: nothing to carry on, or the last one reached its end (Replay).
        case beginning
        /// The saved session, carried on from its place. `mediaTimeMs` is nil when the place isn't known without
        /// reading more (a Library row holds only a percentage, and a text session is placed in characters).
        case savedPlace(mediaTimeMs: Int?)
    }

    public enum Outcome: Equatable, Sendable {
        /// Start the item. Friend Margins ahead of the start play in place as the episode reaches them.
        case play(Start)
        /// Ask first: these friend Margins are behind where Play would start, so the episode would skip them.
        case askFirst(marginsBehind: [SharedMarginReview.Entry])

        public var isAsk: Bool {
            if case .askFirst = self { return true }
            return false
        }
    }

    /// Everything the rule reads.
    public struct Context: Sendable {
        public var itemId: String
        public var surface: Surface
        public var nowPlaying: NowPlaying?
        public var openItem: OpenItem?
        /// The item's Library row, nil when the Library doesn't hold it.
        public var libraryRow: LibraryItemRow?
        /// The friend's Margins the listener hasn't heard and can hear, with their places in this copy.
        public var newMargins: [SharedMarginReview.Entry]
        public var declined: NewMarginsOfferMemory
        /// The item is finished and a new Margin answers one of the listener's own (#4785): a surface that asks asks
        /// about every new Margin, whatever the place, because Play would replay the episode from 0 or not at all.
        public var catchUp: ConversationCatchUp?

        public init(
            itemId: String, surface: Surface, nowPlaying: NowPlaying? = nil, openItem: OpenItem? = nil,
            libraryRow: LibraryItemRow? = nil, newMargins: [SharedMarginReview.Entry] = [],
            declined: NewMarginsOfferMemory = NewMarginsOfferMemory(), catchUp: ConversationCatchUp? = nil
        ) {
            self.catchUp = catchUp
            self.itemId = itemId
            self.surface = surface
            self.nowPlaying = nowPlaying
            self.openItem = openItem
            self.libraryRow = libraryRow
            self.newMargins = newMargins
            self.declined = declined
        }
    }

    /// Where Play starts and whether it asks first.
    ///
    /// The place is, in order: the playhead when this item is playing now (another item playing says nothing about
    /// this one); the place of the session Play resumes when the item is open; the Library row's reading; and 0 for an
    /// item the Library doesn't hold. When the place isn't known (nil) every new Margin counts as behind it, because
    /// none can be ruled out.
    public static func decide(_ context: Context) -> Outcome {
        let start = start(for: context)
        guard context.surface.asksAboutMarginsBehind else { return .play(start) }
        if context.catchUp != nil, !context.newMargins.isEmpty,
           !context.declined.isDeclined(itemId: context.itemId, margins: context.newMargins.map(\.marginId)) {
            return .askFirst(marginsBehind: context.newMargins)
        }
        let behind: [SharedMarginReview.Entry]
        if let now = context.nowPlaying, now.itemId == context.itemId, now.mediaTimeMs == nil, let textOffset = now.textOffset {
            // The article loaded or playing now is read aloud and has no media time: its place is the text being read
            // (#5409). Media 0 against the Margins' narrated positions counted none as behind, so Continue skipped a
            // friend's Margin before the place with no question (audit on #5446).
            behind = marginsBehind(context.newMargins, textOffset: textOffset)
        } else if case .savedPlace(nil) = start, context.nowPlaying?.itemId != context.itemId,
           let open = context.openItem, open.id == context.itemId {
            // The open item resumes a session placed by characters, an article (#5409): compare characters, as the item
            // screen does, so a friend's Margin ahead of the place plays there with no question (#3059). Its media place
            // is unknown, and counting every new Margin as behind asked about Margins ahead (audit on #5422).
            behind = marginsBehindSavedPlace(context.newMargins, sessions: open.sessions, addedAgainAt: open.addedAgainAt)
        } else {
            behind = FriendMarginsPlan.behind(context.newMargins, place: place(of: start, in: context))
        }
        if behind.isEmpty || context.declined.isDeclined(itemId: context.itemId, margins: behind.map(\.marginId)) {
            return .play(start)
        }
        return .askFirst(marginsBehind: behind)
    }

    /// The friend Margins the item screen's Play would skip (#4125): those behind the place `startItem` resumes. It
    /// reads the open item's sessions, so it is for a surface that holds them; `decide` keeps the Library row's own
    /// reading (a row holds no place). Like is compared with like: a media session's playhead against each Margin's
    /// place in the media, a text session's character offset against the Margin's character position. A place that
    /// is unknown on either side is not behind, so an article with a Margin ahead of the place, or with no usable
    /// position, plays in place with no question (#3059). A session at 100%, a finished one or none begins at 0, so
    /// nothing is behind it.
    public static func marginsBehindSavedPlace(
        _ entries: [SharedMarginReview.Entry], sessions: [Session], addedAgainAt: Date?
    ) -> [SharedMarginReview.Entry] {
        guard let session = resumedSession(in: ItemFinishedRule.continuationSessions(addedAgainAt: addedAgainAt, sessions: sessions)) else { return [] }
        if let mediaTimeMs = session.position.mediaTimeMs {
            // Play at the end of the episode has nothing left to cross, so the Margins that play after the others
            // are behind it too, not skipped (#3789). Short of the end they wait for it (#4347).
            let atEnd = session.completionPercent >= ItemFinishedRule.listenedPercent
            return FriendMarginsPlan.behind(entries, place: .known(mediaTimeMs: mediaTimeMs, isAtEnd: atEnd))
        }
        return marginsBehind(entries, textOffset: session.position.charOffset)
    }

    /// The Margins before a place in the text, compared by character; a Margin with no character place is not behind.
    static func marginsBehind(_ entries: [SharedMarginReview.Entry], textOffset: Int) -> [SharedMarginReview.Entry] {
        guard textOffset > 0 else { return [] }
        return entries.filter { ($0.interjection.resolution.localStartChar ?? .max) < textOffset }
    }

    /// What the item screen's two pinned buttons are built from (#4125): the Margins behind the saved place, or none
    /// when the listener already turned them down in this run (`NewMarginsOfferMemory`, the same memory the Library
    /// row's question keeps). Empty means the screen shows today's Play and "Skip to <friend>'s Margins".
    public static func itemScreenMarginsBehind(
        _ entries: [SharedMarginReview.Entry], itemId: String, sessions: [Session], addedAgainAt: Date?,
        declined: NewMarginsOfferMemory
    ) -> [SharedMarginReview.Entry] {
        let behind = marginsBehindSavedPlace(entries, sessions: sessions, addedAgainAt: addedAgainAt)
        return declined.isDeclined(itemId: itemId, margins: behind.map(\.marginId)) ? [] : behind
    }

    /// The saved place is at the very end: the session Play resumes is at 99% or more, but not at 100%, where Play
    /// begins again (`SessionContinuation.continueResumes`). Resuming there plays the last seconds and finishes, so
    /// "without the Margins" is better said as starting over (#4125).
    public static func savedPlaceIsAtEnd(sessions: [Session], addedAgainAt: Date?) -> Bool {
        (resumedSession(in: ItemFinishedRule.continuationSessions(addedAgainAt: addedAgainAt, sessions: sessions))?.completionPercent ?? 0) >= ItemFinishedRule.listenedPercent
    }

    /// Whether the question the Library row asks (`decide` returning `.askFirst`) is about a saved place at the very
    /// end of the episode: 99% up to, not including, 100%. Then "Listen without them" would resume for the last few
    /// seconds and finish, so the question offers "Play from the start" instead, as the item screen's second button
    /// does (#4125, state D). The open item says it from its sessions; an item that is not open, from its Library row's
    /// percentage (the row's own session already leaves out an item added again, #4183). Whether the item is loaded
    /// or playing makes no difference: a relaunch restores the newest session as the loaded, paused one, so "now
    /// playing" is also where a listener who heard it to the end finds it.
    public static func askedPlaceIsAtEnd(_ context: Context) -> Bool {
        if let open = context.openItem, open.id == context.itemId {
            return savedPlaceIsAtEnd(sessions: open.sessions, addedAgainAt: open.addedAgainAt)
        }
        guard let row = context.libraryRow, row.hasContinuationSession, let percent = row.continuationProgressPercent else { return false }
        return percent >= ItemFinishedRule.listenedPercent && percent < ItemFinishedRule.atEndPercent
    }

    private static func resumedSession(in sessions: [Session]) -> Session? {
        guard let session = SessionContinuation.preferredContinuationSession(in: sessions),
              SessionContinuation.continueResumes(session) else { return nil }
        return session
    }

    /// What `startItem` does with the item's saved sessions: carry on the one Play resumes, else begin a new one.
    public enum StartAction: Equatable, Sendable {
        case resume(Session)
        case startNew
    }

    /// `addedAgainAt` is required: an item finished and then added again starts over, so its old finished sessions
    /// (including one at 99%, which would resume near its end) never decide the start (#4183).
    public static func startAction(sessions: [Session], addedAgainAt: Date?) -> StartAction {
        let sessions = ItemFinishedRule.continuationSessions(addedAgainAt: addedAgainAt, sessions: sessions)
        if let session = SessionContinuation.preferredContinuationSession(in: sessions), SessionContinuation.continueResumes(session) {
            return .resume(session)
        }
        return .startNew
    }

    /// Where a catch-up run starts (#4785): it resumes only a re-listen the listener left short of the end (under
    /// `ItemFinishedRule.listenedPercent`), and otherwise begins a new session. A finished session, or one at 99% or
    /// more, is never moved, so every fact that made the item finished survives the run.
    public static func catchUpStart(sessions: [Session], addedAgainAt: Date?) -> StartAction {
        if case .resume(let session) = startAction(sessions: sessions, addedAgainAt: addedAgainAt),
           session.completionPercent < ItemFinishedRule.listenedPercent {
            return .resume(session)
        }
        return .startNew
    }

    static func start(for context: Context) -> Start {
        if let now = context.nowPlaying, now.itemId == context.itemId { return .savedPlace(mediaTimeMs: now.mediaTimeMs ?? 0) }
        if let open = context.openItem, open.id == context.itemId {
            switch startAction(sessions: open.sessions, addedAgainAt: open.addedAgainAt) {
            case .startNew: return .beginning
            case .resume:
                let counted = ItemFinishedRule.continuationSessions(addedAgainAt: open.addedAgainAt, sessions: open.sessions)
                return .savedPlace(mediaTimeMs: SessionContinuation.continuePlaceMs(sessions: counted))
            }
        }
        guard let row = context.libraryRow else { return .beginning }
        return row.continuePlaceMs == 0 ? .beginning : .savedPlace(mediaTimeMs: nil) // a row holds no place
    }

    private static func place(of start: Start, in context: Context) -> FriendMarginsPlan.Place {
        switch start {
        case .beginning: return .known(mediaTimeMs: 0, isAtEnd: false)
        case .savedPlace(let ms):
            guard let ms else { return .unknown }
            // The playhead of what is playing now is not at the end (the episode's end plays its own Margins); a saved
            // session left at 99% is, and only the open item's sessions say so.
            let playingNow = context.nowPlaying?.itemId == context.itemId
            var isAtEnd = false
            if !playingNow, let open = context.openItem, open.id == context.itemId {
                isAtEnd = savedPlaceIsAtEnd(sessions: open.sessions, addedAgainAt: open.addedAgainAt)
            }
            return .known(mediaTimeMs: ms, isAtEnd: isAtEnd)
        }
    }
}
