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
        /// The item screen's Play, beside "Skip to <friend>'s Margins". It starts the episode in place with no
        /// question (#3219), so a Margin behind a saved place is skipped. That is how `main` behaves and issue #4125
        /// is about changing it; when it is decided, this is the case that changes.
        case itemScreen

        var asksAboutMarginsBehind: Bool { self == .libraryRow }
    }

    /// What is playing now, when something is.
    public struct NowPlaying: Equatable, Sendable {
        public let itemId: String
        /// The playhead in the media, or nil when the player doesn't report one yet.
        public let mediaTimeMs: Int?
        public init(itemId: String, mediaTimeMs: Int?) {
            self.itemId = itemId
            self.mediaTimeMs = mediaTimeMs
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

        public init(
            itemId: String, surface: Surface, nowPlaying: NowPlaying? = nil, openItem: OpenItem? = nil,
            libraryRow: LibraryItemRow? = nil, newMargins: [SharedMarginReview.Entry] = [],
            declined: NewMarginsOfferMemory = NewMarginsOfferMemory()
        ) {
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
        let behind = SharedMarginReview.entriesBehind(context.newMargins, placeMs: place(of: start))
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
    public static func marginsBehindSavedPlace(_ entries: [SharedMarginReview.Entry], sessions: [Session]) -> [SharedMarginReview.Entry] {
        guard let session = resumedSession(in: sessions) else { return [] }
        if let mediaTimeMs = session.position.mediaTimeMs {
            return entries.filter { $0.mediaTimeMs < mediaTimeMs }
        }
        let charOffset = session.position.charOffset
        guard charOffset > 0 else { return [] }
        return entries.filter { ($0.interjection.resolution.localStartChar ?? .max) < charOffset }
    }

    /// The saved place is at the very end: the session Play resumes is at 99% or more, but not at 100%, where Play
    /// begins again (`SessionContinuation.continueResumes`). Resuming there plays the last seconds and finishes, so
    /// "without the Margins" is better said as starting over (#4125).
    public static func savedPlaceIsAtEnd(sessions: [Session]) -> Bool {
        (resumedSession(in: sessions)?.completionPercent ?? 0) >= 99
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

    private static func place(of start: Start) -> Int? {
        switch start {
        case .beginning: return 0
        case .savedPlace(let ms): return ms
        }
    }
}
