import Foundation

/// The one place live-session disk work runs (#2487, #2256): the session store (`LiveSessionCollection`), the Watch
/// Margins that arrive, and moving received recordings into place. It is an actor, so none of it runs on the main
/// thread and its reads and writes happen one at a time, in a fixed order. The app's screens keep a session in
/// memory and publish what comes back on the main actor. New live-session file work goes here, not on a
/// `@MainActor` type.
///
/// Every Margin that arrives with no screen to take it, from the Watch or the Lock Screen, is filed by
/// `LiveSessionFiling`: into a session, onto the item our player was playing, or into a quick session. Nothing
/// waits for a session to exist (slice 1a: the hidden inbox goes).
public actor LiveSessionFileWorker {
    /// The app's worker, rooted at Application Support (where `Gate1AppModel.liveSessionDirectory` points).
    public static let shared = LiveSessionFileWorker(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    )

    /// A spoken Margin filed into a session, waiting for its transcript.
    public struct FiledMargin: Equatable, Sendable {
        public var marginId: String
        public var audioPath: String

        public init(marginId: String, audioPath: String) {
            self.marginId = marginId
            self.audioPath = audioPath
        }
    }

    /// A Margin that belongs on the item our own player was playing (DESIGN section 2 point 12). The app writes it
    /// onto the item; if it can't, it hands it back with `fileAsQuick`.
    public struct PlayerPlacement: Equatable, Sendable {
        public var marginId: String
        public var itemId: String
        public var positionMs: Int
        public var markedAt: Date
        /// A spoken Margin's recording, already in place. Nil for a Mark.
        public var audioPath: String?
        public var durationMs: Int?
        public var spokenOn: String?
        /// A Watch recording still waiting in the landing folder and the inbox: nothing is cleared until the Margin is
        /// somewhere the listener can see it (`completePlacement`), so an app that ends in between loses nothing (#2542).
        public var pending: PendingWatchCapture?
        /// The listener chose "On this episode" on the Watch (#3494): the answer says so.
        public var aimedAtItem: Bool = false
        /// Where it was meant to go, kept on the Margin if the item refuses it and it files into a session instead
        /// (#4233 Design 2.9.1 case 2). Nil reads as `itemId` at `positionMs` from the player.
        public var playingThen: LiveSessionPlayingThen?
    }

    /// What a deferred Watch Margin needs to be answered and cleared once it is placed.
    public struct PendingWatchCapture: Equatable, Sendable {
        public var captureId: String
        public var receipt: WatchMarginReceipt
        /// The landing files' path without an extension (`<stem>.json` and `<stem>.m4a`).
        public var landedStem: String
    }

    /// What one filing pass did.
    public struct Pass: Equatable, Sendable {
        public var filed: [FiledMargin] = []
        public var placements: [PlayerPlacement] = []
        public var answers: [WatchMarginAnswer] = []
        /// True when a stored session changed.
        public var changed = false

        public init() {}
    }

    /// A line for the Library's Live row.
    public struct Summary: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var kind: ElsewhereKind
        public var isQuick: Bool
        public var isRunning: Bool
        public var startedAt: Date
        public var endedAt: Date?
        public var marginCount: Int
        /// When Resume stops being offered, while it is (#2883).
        public var resumableUntil: Date?

        /// Public so the app's tests can put rows on the Live row (#3723); the worker builds them the same way.
        public init(
            id: String, title: String, kind: ElsewhereKind, isQuick: Bool, isRunning: Bool, startedAt: Date,
            endedAt: Date?, marginCount: Int, resumableUntil: Date?
        ) {
            self.id = id
            self.title = title
            self.kind = kind
            self.isQuick = isQuick
            self.isRunning = isRunning
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.marginCount = marginCount
            self.resumableUntil = resumableUntil
        }
    }

    /// Application Support: the store is `LiveSession/…` under it, and recording paths ("SpokenMargins/interjections/…")
    /// are relative to it.
    public nonisolated let root: URL?
    let collection: LiveSessionCollection?
    /// The store in memory, read once (after taking in `current.json`) and written through.
    private var cache: [String: LiveSession]?
    var deletions = LiveSessionFiling.Deletions()
    private var watchInbox: WatchMarginInbox?
    /// The newest screen save written, per session. A save the screen made earlier that arrives later is dropped,
    /// so an older copy never overwrites a newer one.
    private var writtenGeneration: [String: Int] = [:]
    /// What this worker filed into a session that the screen's copy may not have taken in yet: Margins and
    /// transcripts by Margin id, per session. A screen save that lacks them puts them back, so a save racing the
    /// screen's reconcile never drops a Margin or its words. Each entry is cleared once a screen save carries it.
    private var unseenMargins: [String: [String: LiveSessionMargin]] = [:]
    private var unseenTranscripts: [String: [String: String]] = [:]
    /// A start, End or Resume from the Watch that the screen's copy may not have taken in yet, per session (#2487
    /// slice 1b). A screen save that lacks it gets it back, so a stale save never reopens or re-ends a session.
    var unseenLifecycle: [String: Lifecycle] = [:]

    struct Lifecycle: Equatable {
        var startedAt: Date
        var endedAt: Date?
        var endTappedAt: Date?
        var endReason: String?
        var endNote: String?
        var resumedAt: Date?

        init(_ session: LiveSession) {
            startedAt = session.startedAt
            endedAt = session.endedAt
            endTappedAt = session.endTappedAt
            endReason = session.endReason
            endNote = session.endNote
            resumedAt = session.resumedAt
        }

        func apply(to session: inout LiveSession) {
            session.startedAt = startedAt
            session.endedAt = endedAt
            session.endTappedAt = endTappedAt
            session.endReason = endReason
            session.endNote = endNote
            session.resumedAt = resumedAt
        }
    }
    private let makeId: @Sendable () -> String

    public init(root: URL?, makeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.root = root
        self.collection = root.map(LiveSessionCollection.init(root:))
        self.makeId = makeId
    }

    /// Where a received Watch file lands, with its metadata beside it, until the next filing pass. The build before
    /// this one kept Margins waiting here for a session; the first pass files them by the new rule.
    public nonisolated var inboxDirectory: URL? {
        root?
            .appending(path: "LiveSession", directoryHint: .isDirectory)
            .appending(path: "WatchInbox", directoryHint: .isDirectory)
    }

    /// `WatchMarginInbox`'s folder: each received recording, checked and stored durably before it is answered.
    public nonisolated var receivedDirectory: URL? {
        root?
            .appending(path: "LiveSession", directoryHint: .isDirectory)
            .appending(path: "WatchReceived", directoryHint: .isDirectory)
    }

    /// The Application Support location of a recorder-style path ("SpokenMargins/interjections/…").
    public nonisolated func recordingURL(for audioPath: String) -> URL? {
        root?.appending(path: audioPath)
    }

    // MARK: Reading

    @discardableResult
    func sessions() -> [String: LiveSession] {
        if let cache { return cache }
        guard let collection else { return [:] }
        try? collection.migrateLegacyCurrent()
        deletions = collection.loadDeletions()
        let loaded = Dictionary(collection.loadAll().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cache = loaded
        return loaded
    }

    /// The session `current.json` holds: the running named session, else the most recently ended one not yet saved.
    public func load() -> LiveSession? {
        LiveSessionCollection.legacyMirror(of: Array(sessions().values))
    }

    /// The running named session, if any.
    public func runningSession() -> LiveSession? {
        sessions().values
            .filter { $0.isQuick != true && $0.savedItemId == nil && $0.endedAt == nil }
            .max { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    public func session(id: String) -> LiveSession? {
        sessions()[id]
    }

    /// When each Margin saved from a live session was made there, by its id in the database (`LiveSessionRecord`). The
    /// database holds the save time for these; the record keeps the real one.
    public func savedMarginTimes() -> [String: Date] {
        guard let root else { return [:] }
        return TodaysMarginsDigest.madeAt(records: LiveSessionRecord.loadAll(from: root))
    }

    public func allSessions() -> [LiveSession] {
        sessions().values.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    public func currentDeletions() -> LiveSessionFiling.Deletions {
        sessions()
        return deletions
    }

    /// The sessions not yet saved, for the Library's Live row: the running one first, then the most recent.
    public func summaries(now: Date = Date()) -> [Summary] {
        let all = sessions()
        return all.values
            .filter { $0.savedItemId == nil }
            .map { session in
                Summary(
                    id: session.id, title: Self.title(of: session), kind: session.kind, isQuick: session.isQuick == true,
                    isRunning: session.isQuick != true && session.endedAt == nil,
                    startedAt: session.startedAt, endedAt: session.endedAt, marginCount: session.margins.count,
                    resumableUntil: LiveSessionWatchSessions.resumableUntil(id: session.id, sessions: all).flatMap { $0 > now ? $0 : nil }
                )
            }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return (lhs.endedAt ?? now, lhs.id) > (rhs.endedAt ?? now, rhs.id)
            }
    }

    /// Spoken Margins in unsaved sessions that have no words yet.
    public func spokenWithoutWords() -> [FiledMargin] {
        sessions().values
            .filter { $0.savedItemId == nil }
            .flatMap(\.margins)
            .compactMap { margin in
                guard let path = margin.audioPath, margin.spokenTranscript == nil else { return nil }
                return FiledMargin(marginId: margin.id, audioPath: path)
            }
    }

    // MARK: The screen's saves

    /// Writes the screen's copy of a session. `generation` rises with each screen save or discard; a lower one than
    /// already written for that session is stale and is skipped (returns false). So is a save of a deleted session.
    @discardableResult
    public func save(_ session: LiveSession, generation: Int) throws -> Bool {
        sessions()
        guard collection != nil, generation > writtenGeneration[session.id, default: 0],
              !deletions.deletedSession(session.id) else { return false }
        writtenGeneration[session.id] = generation
        var merged = keepingUnseen(in: session)
        merged.savedItemId = merged.savedItemId ?? sessions()[session.id]?.savedItemId
        // A Margin deleted, or moved to another session meanwhile, stays where it is.
        let elsewhere = Set(sessions().values.filter { $0.id != session.id }.flatMap { $0.margins.map(\.id) })
        merged.margins.removeAll { deletions.marginIds.contains($0.id) || elsewhere.contains($0.id) }
        if merged.isQuick == true, merged.margins.isEmpty { return false }
        // A new named session: the later start ends the earlier one (slice 1b; DESIGN default 1).
        if sessions()[merged.id] == nil, LiveSessionWatchSessions.isRunningNamed(merged) {
            let all = LiveSessionWatchSessions.phoneStarted(merged, sessions: sessions())
            if all[0].endedAt != nil { unseenLifecycle[merged.id] = Lifecycle(all[0]) }
            for other in all.dropFirst() {
                if let before = sessions()[other.id] { noteUnseen(from: before, to: other) }
                unseenLifecycle[other.id] = Lifecycle(other)
            }
            try persist(all)
            return true
        }
        try persist([merged])
        return true
    }

    /// Deletes a session: it leaves the store, and its span and Margin ids are recorded, so a late copy of one of its
    /// Margins is refused.
    public func discard(sessionId: String, generation: Int, now: Date = Date()) {
        guard let collection, generation > writtenGeneration[sessionId, default: 0] else { return }
        writtenGeneration[sessionId] = generation
        var all = sessions()
        if let session = all[sessionId] {
            deletions.sessions.append(.init(id: sessionId, startedAt: session.startedAt, endedAt: session.endedAt ?? now))
            deletions.marginIds.formUnion(session.margins.map(\.id))
        } else if !deletions.deletedSession(sessionId) {
            deletions.sessions.append(.init(id: sessionId, startedAt: now, endedAt: now))
        }
        try? collection.saveDeletions(deletions)
        all[sessionId] = nil
        cache = all
        collection.remove(id: sessionId)
        photoStore?.removeFolder(sessionId: sessionId) // a discarded session's photos go with it (#2708)
        unseenMargins[sessionId] = nil
        unseenTranscripts[sessionId] = nil
        try? collection.writeLegacyMirror(Array(all.values))
    }

    /// Notes that the listener deleted one Margin, so a late copy never brings it back.
    public func forgetMargin(id: String) {
        guard let collection else { return }
        sessions()
        deletions.marginIds.insert(id)
        try? collection.saveDeletions(deletions)
        for sessionId in unseenMargins.keys { unseenMargins[sessionId]?[id] = nil }
    }

    /// The session became a Library item. It stays in the store, takes no new Margins and leaves `current.json`.
    public func markSaved(sessionId: String, itemId: String, now: Date = Date()) {
        guard var session = sessions()[sessionId] else { return }
        session.savedItemId = itemId
        if session.endedAt == nil { session.endedAt = now }
        try? persist([session])
    }

    /// Changes the session holding `marginId` and saves it when `body` returns true. Returns the saved session, or nil
    /// when no session holds it, nothing changed or the save failed.
    @discardableResult
    public func update(marginId: String, _ body: @Sendable (inout LiveSession) -> Bool) -> LiveSession? {
        guard let before = sessions().values.first(where: { $0.margins.contains { $0.id == marginId } }) else { return nil }
        var session = before
        guard body(&session) else { return nil }
        noteUnseen(from: before, to: session)
        do {
            try persist([session])
        } catch {
            return nil
        }
        return session
    }

    /// Files a spoken Margin recorded on the phone into the stored session `sessionId`, whatever screen is or isn't
    /// open (#3489). A Margin is never lost because its screen closed, the phone locked or the session ended while
    /// it recorded: an ended session takes it too, at the moment it was started. A screen save that hasn't seen it
    /// keeps it (`keepingUnseen`). Returns the saved session, or nil when the session was discarded, the Margin is
    /// already there or the save failed.
    @discardableResult
    public func attachSpokenMargin(
        sessionId: String, marginId: String, audioPath: String, markedAt: Date, durationMs: Int?, spokenOn: String,
        photo: LiveSessionPhoto? = nil
    ) -> LiveSession? {
        let stored = sessions() // loads the deletions too
        guard !deletions.deletedSession(sessionId), !deletions.marginIds.contains(marginId),
              let before = stored[sessionId] else { return nil }
        var session = before
        guard session.attachSpokenMargin(
            id: marginId, audioPath: audioPath, markedAt: markedAt, durationMs: durationMs, spokenOn: spokenOn
        ) else { return nil }
        // The photo's file is already in place (#2708), so the one save writes the Margin and the reference together.
        if let photo, let index = session.margins.firstIndex(where: { $0.id == marginId }) {
            session.margins[index].photo = photo
        }
        noteUnseen(from: before, to: session)
        do {
            try persist([session])
        } catch {
            return nil
        }
        return session
    }

    // MARK: Photos (#2708)

    /// The result of filing a spoken Margin that came with a photo.
    public struct PhotoFiling: Equatable, Sendable {
        /// The saved session, nil when the session was discarded, the Margin is already there or the save failed.
        public var session: LiveSession?
        /// True when the picture could not be kept (the file could not be moved), so the Margin was saved without it. The
        /// listener never loses their words because of the picture.
        public var photoFailed: Bool
    }

    /// Where photos live: under the same root as the sessions. Nil with no root (a worker with nothing on disk).
    nonisolated var photoStore: LiveSessionPhotoStore? {
        root.map { LiveSessionPhotoStore(root: $0) }
    }

    /// Moves a staged photo to `live-photos/<session>/<margin>.jpg` and returns the reference to save with the Margin.
    /// Nil when it could not be moved; the staged file is discarded then, because the Margin is saved without it.
    public func commitPhoto(_ staged: LiveSessionPhotoStore.Staged, sessionId: String, marginId: String) -> LiveSessionPhoto? {
        guard let store = photoStore else { return nil }
        do {
            return try store.commit(staged, sessionId: sessionId, marginId: marginId)
        } catch {
            store.discard(staged)
            return nil
        }
    }

    /// Files a spoken Margin that was taken with a photo: the file is moved into place first, then the Margin that
    /// names it is saved. When the Margin can't be saved the file is removed again, so nothing is left that no Margin names.
    public func attachSpokenMargin(
        sessionId: String, marginId: String, audioPath: String, markedAt: Date, durationMs: Int?, spokenOn: String,
        staged: LiveSessionPhotoStore.Staged
    ) -> PhotoFiling {
        let photo = commitPhoto(staged, sessionId: sessionId, marginId: marginId)
        let saved = attachSpokenMargin(
            sessionId: sessionId, marginId: marginId, audioPath: audioPath, markedAt: markedAt, durationMs: durationMs,
            spokenOn: spokenOn, photo: photo
        )
        if saved == nil, let photo { photoStore?.remove(photo) }
        return PhotoFiling(session: saved, photoFailed: photo == nil)
    }

    /// Deleting a Margin deletes its photo file (and the session's folder when it was the last one).
    public func removePhoto(_ photo: LiveSessionPhoto) {
        photoStore?.remove(photo)
    }

    /// Cancel: a staged photo that was never saved is deleted.
    public func discardStaged(_ staged: LiveSessionPhotoStore.Staged) {
        photoStore?.discard(staged)
    }

    /// The launch sweep: removes the files under `live-photos/` that no Margin names. Run it once at launch, before any
    /// live-session screen opens. Nil when there is no store on disk.
    @discardableResult
    public func sweepPhotos() -> LiveSessionPhotoStore.SweepResult? {
        guard let store = photoStore, let collection else { return nil }
        let readable = Array(sessions().values) // reading also upgrades the store the way every first read does
        return store.sweep(readable: readable, in: collection)
    }

    /// Files a written Margin (dictated to Siri, #3880) into the running named session at `markedAt`, whatever screen is
    /// or isn't open. A screen save that hasn't seen it keeps it (`keepingUnseen`). Writes only into a running session:
    /// returns nil when none runs, the text is empty or the save failed, and never starts or reopens one.
    @discardableResult
    public func addWrittenMargin(text: String, markedAt: Date) -> LiveSession? {
        fileWrittenMargin(text: text, markedAt: markedAt, staged: nil).session
    }

    /// The same with a picture handed to Add Margin (#4925). The picture is moved into place first and the Margin that
    /// names it saved after; when the Margin can't be saved the file goes again. The staged file is always consumed: kept
    /// with the Margin or deleted. A picture that can't be kept never costs the words (`photoFailed`).
    public func addWrittenMargin(text: String, markedAt: Date, staged: LiveSessionPhotoStore.Staged) -> PhotoFiling {
        fileWrittenMargin(text: text, markedAt: markedAt, staged: staged)
    }

    private func fileWrittenMargin(text: String, markedAt: Date, staged: LiveSessionPhotoStore.Staged?) -> PhotoFiling {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let before = runningSession() else {
            if let staged { photoStore?.discard(staged) }
            return PhotoFiling(session: nil, photoFailed: false)
        }
        var margin = LiveSessionMargin(id: "siri-\(makeId())", text: words, markedAt: markedAt)
        let photo = staged.flatMap { commitPhoto($0, sessionId: before.id, marginId: margin.id) }
        margin.photo = photo
        var session = before
        session.add(margin)
        noteUnseen(from: before, to: session)
        do {
            try persist([session])
        } catch {
            if let photo { photoStore?.remove(photo) }
            return PhotoFiling(session: nil, photoFailed: staged != nil)
        }
        return PhotoFiling(session: session, photoFailed: staged != nil && photo == nil)
    }

    /// Files a written Margin (dictated to Siri, #3880 slice 2) when no live session runs and the player has nothing: by
    /// the same rule as `fileAsQuickSession` with the player left out, so it joins a quick session that holds this moment,
    /// else starts one, and never goes to a Library item. Returns the session it went into, or nil when the text is empty
    /// or the save failed. Like `addWrittenMargin`, a screen save that hasn't seen it keeps it (`keepingUnseen`).
    @discardableResult
    public func fileWrittenMarginAsQuick(text: String, markedAt: Date, now: Date = Date()) -> LiveSession? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        return fileIntoQuickSession(LiveSessionMargin(id: "siri-\(makeId())", text: words, markedAt: markedAt), now: now).session
    }

    /// The same with a picture handed to Add Margin (#4925); the staged file is consumed as for `addWrittenMargin`.
    public func fileWrittenMarginAsQuick(
        text: String, markedAt: Date, now: Date = Date(), staged: LiveSessionPhotoStore.Staged
    ) -> PhotoFiling {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            photoStore?.discard(staged)
            return PhotoFiling(session: nil, photoFailed: false)
        }
        return fileIntoQuickSession(LiveSessionMargin(id: "siri-\(makeId())", text: words, markedAt: markedAt), now: now, staged: staged)
    }

    /// Files a spoken Margin recorded on the phone when nothing runs (Record a Margin with no live session and no item
    /// in the player, #4927): by the same rule as `fileWrittenMarginAsQuick`, so it joins a quick session that holds
    /// this moment, else starts one, and never goes to a Library item. `markedAt` is when the recording began. Returns
    /// the session it went into, or nil when the Margin was deleted meanwhile, is already filed or the save failed.
    /// Like a written one, a screen save that hasn't seen it keeps it (`keepingUnseen`).
    @discardableResult
    public func fileSpokenMarginAsQuick(
        marginId: String, audioPath: String, markedAt: Date, durationMs: Int?, spokenOn: String, now: Date = Date()
    ) -> LiveSession? {
        spokenMarginForQuick(marginId: marginId, audioPath: audioPath, markedAt: markedAt, durationMs: durationMs, spokenOn: spokenOn)
            .flatMap { fileIntoQuickSession($0, now: now).session }
    }

    /// The same with a picture handed to Add Voice Margin (#4925); the staged file is consumed as for `addWrittenMargin`.
    public func fileSpokenMarginAsQuick(
        marginId: String, audioPath: String, markedAt: Date, durationMs: Int?, spokenOn: String, now: Date = Date(),
        staged: LiveSessionPhotoStore.Staged
    ) -> PhotoFiling {
        guard let margin = spokenMarginForQuick(
            marginId: marginId, audioPath: audioPath, markedAt: markedAt, durationMs: durationMs, spokenOn: spokenOn
        ) else {
            photoStore?.discard(staged)
            return PhotoFiling(session: nil, photoFailed: false)
        }
        return fileIntoQuickSession(margin, now: now, staged: staged)
    }

    /// The Margin to file, or nil when it was deleted meanwhile or is already filed.
    private func spokenMarginForQuick(
        marginId: String, audioPath: String, markedAt: Date, durationMs: Int?, spokenOn: String
    ) -> LiveSessionMargin? {
        sessions() // loads the deletions too
        guard !deletions.marginIds.contains(marginId),
              !sessions().values.contains(where: { $0.margins.contains { $0.id == marginId } }) else { return nil }
        var margin = LiveSessionMargin(id: marginId, text: "", markedAt: markedAt)
        margin.audioPath = audioPath
        margin.durationMs = durationMs
        margin.spokenOn = spokenOn
        return margin
    }

    /// The one rule for a Margin that goes to a quick session with the player left out. A staged picture is moved to the
    /// session the Margin lands in before the Margin is saved, and removed again when the save files nothing.
    private func fileIntoQuickSession(
        _ margin: LiveSessionMargin, now: Date, staged: LiveSessionPhotoStore.Staged? = nil
    ) -> PhotoFiling {
        sessions() // loads the deletions too
        let decision = LiveSessionFiling.decide(
            .init(marginId: margin.id, markedAt: margin.markedAt, allowsPlayerItem: false),
            sessions: candidates(), deletions: deletions, playerRuns: [], now: now
        )
        let newId = "quick-\(makeId())"
        var placing = margin
        var photo: LiveSessionPhoto?
        if let staged {
            switch decision {
            case let .joinQuick(id), let .session(id, _): photo = commitPhoto(staged, sessionId: id, marginId: margin.id)
            case .newQuick: photo = commitPhoto(staged, sessionId: newId, marginId: margin.id)
            default: photoStore?.discard(staged)
            }
            placing.photo = photo
        }
        guard let placed = (try? place(placing, by: decision, newQuickId: newId)) ?? nil else {
            if let photo { photoStore?.remove(photo) }
            return PhotoFiling(session: nil, photoFailed: staged != nil)
        }
        var pass = Pass()
        tidy(now: now, pass: &pass)
        return PhotoFiling(session: sessions()[placed.id] ?? placed, photoFailed: staged != nil && photo == nil)
    }

    // MARK: Filing

    /// Files each received Watch Margin by `LiveSessionFiling`: stored in `WatchMarginInbox` first, then filed, and only
    /// then answered (the answers come back for the app to send). A recording that couldn't be stored or moved stays
    /// for the next pass. A repeat of one already filed is answered "already filed" and cleared.
    public func fileWatchInbox(playerRuns: [LiveSessionFiling.PlayerRun] = [], now: Date = Date()) -> Pass {
        var pass = Pass()
        guard let landing = inboxDirectory, let inbox = openWatchInbox() else { return pass }
        sessions()
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: landing, includingPropertiesForKeys: nil)) ?? []
        for metadataURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where metadataURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: metadataURL),
                  let transfer = try? JSONDecoder().decode(WatchMarginTransfer.self, from: data) else {
                try? fileManager.removeItem(at: metadataURL)
                continue
            }
            let audioURL = metadataURL.deletingPathExtension().appendingPathExtension("m4a")
            if let answer = fileOne(transfer, landedAt: audioURL, inbox: inbox, playerRuns: playerRuns, now: now, pass: &pass) {
                pass.answers.append(answer)
                try? fileManager.removeItem(at: audioURL)
                try? fileManager.removeItem(at: metadataURL)
            }
        }
        tidy(now: now, pass: &pass)
        return pass
    }

    /// Files Lock Screen Marks by the same rule (slice 1a point 7). Each is a blind Margin with no words.
    public func fileMarks(_ times: [Date], playerRuns: [LiveSessionFiling.PlayerRun] = [], now: Date = Date()) -> Pass {
        var pass = Pass()
        guard collection != nil else { return pass }
        sessions()
        for time in times {
            let id = "mark-\(Int((time.timeIntervalSince1970 * 1_000).rounded()))"
            let margin = LiveSessionMargin(id: id, text: "", markedAt: time, isBlindMark: true)
            let incoming = LiveSessionFiling.Incoming(marginId: id, markedAt: time)
            let decision = LiveSessionFiling.decide(incoming, sessions: candidates(), deletions: deletions, playerRuns: playerRuns, now: now)
            let hint = LiveSessionFiling.playingThen(for: incoming, decision: decision, playerRuns: playerRuns)
            if case let .playerItem(itemId, positionMs) = decision {
                pass.placements.append(PlayerPlacement(
                    marginId: id, itemId: itemId, positionMs: positionMs, markedAt: time, playingThen: hint
                ))
                continue
            }
            if (try? place(margin, by: decision, playingThen: hint)) != nil { pass.changed = true }
        }
        tidy(now: now, pass: &pass)
        return pass
    }

    /// A Margin the player's item couldn't take files into a session instead, by the rest of the rule.
    @discardableResult
    public func fileAsQuick(_ placement: PlayerPlacement, now: Date = Date()) -> Bool {
        fileAsQuickSession(placement, now: now) != nil
    }

    /// `fileAsQuick`, giving the session the Margin went into (nil when it could not be filed).
    public func fileAsQuickSession(_ placement: PlayerPlacement, now: Date = Date()) -> LiveSession? {
        sessions()
        var margin = LiveSessionMargin(id: placement.marginId, text: "", markedAt: placement.markedAt, isBlindMark: placement.audioPath == nil)
        margin.audioPath = placement.audioPath
        margin.durationMs = placement.durationMs
        margin.spokenOn = placement.spokenOn
        // The item refused it: the session keeps where it was meant to go (#4233 Design 2.9.1 case 2).
        margin.playingThen = placement.playingThen
            ?? LiveSessionPlayingThen(itemId: placement.itemId, positionMs: placement.positionMs, source: .playerRun)
        let decision = LiveSessionFiling.decide(
            .init(marginId: placement.marginId, markedAt: placement.markedAt, allowsPlayerItem: false),
            sessions: candidates(), deletions: deletions, playerRuns: [], now: now
        )
        let placed: LiveSession?
        if case let .alreadyFiled(sessionId) = decision {
            placed = sessions()[sessionId] // a retry after the first try got as far as the session
        } else {
            placed = (try? place(margin, by: decision)) ?? nil
        }
        guard let session = placed else { return nil }
        var pass = Pass()
        tidy(now: now, pass: &pass)
        return sessions()[session.id] ?? session
    }

    /// The Margin is where the listener can see it (on the item when `session` is nil, else in `session`): clears the
    /// recording from the landing folder and the inbox and returns the answer for the Watch, naming where it really went.
    /// Nil for a placement with no Watch recording (a Mark).
    public func completePlacement(_ placement: PlayerPlacement, in session: LiveSession? = nil) -> WatchMarginAnswer? {
        guard let pending = placement.pending else { return nil }
        if let inbox = openWatchInbox() {
            try? inbox.markIncorporated(pending.captureId)
            dropStoredAudio(inbox, pending.captureId)
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: pending.landedStem + ".m4a")
        try? fileManager.removeItem(atPath: pending.landedStem + ".json")
        guard let session else {
            return WatchMarginAnswer(
                receipt: pending.receipt, outcome: .filed, filedIn: placement.aimedAtItem ? "this episode" : "what was playing",
                positionMs: placement.positionMs
            )
        }
        return WatchMarginAnswer(
            receipt: pending.receipt, outcome: .filed, sessionId: session.id, filedIn: Self.name(of: session),
            positionMs: session.margins.first { $0.id == placement.marginId }?.sessionOffsetMs
        )
    }

    /// Stores, files and answers one Watch Margin. Nil leaves it in the landing folder for the next pass.
    private func fileOne(
        _ transfer: WatchMarginTransfer, landedAt audioURL: URL, inbox: WatchMarginInbox,
        playerRuns: [LiveSessionFiling.PlayerRun], now: Date, pass: inout Pass
    ) -> WatchMarginAnswer? {
        let fileManager = FileManager.default
        let captureId = WatchMarginTransfer.safeFileStem(transfer.id)
        if let entry = inbox.entry(captureId), entry.state == .incorporated {
            let receipt = WatchMarginReceipt(captureId: captureId, sha256: entry.metadata.sha256, status: .duplicate)
            return alreadyFiledAnswer(receipt, marginId: transfer.marginId)
        }
        guard fileManager.fileExists(atPath: audioURL.path),
              let digest = try? WatchMarginFolderStore<WatchMarginInbox.Entry>.digest(of: audioURL) else {
            // The build before this one may have moved the recording already; a repeat of a filed Margin is cleared.
            if candidates().contains(where: { $0.marginIds.contains(transfer.marginId) }) {
                return alreadyFiledAnswer(WatchMarginReceipt(captureId: captureId, sha256: "", status: .duplicate), marginId: transfer.marginId)
            }
            return nil
        }
        // The Watch's own checksum, when it sent one, so a damaged copy is caught and sent again (slice 1b).
        let metadata = WatchMarginTransferMetadata(
            captureId: captureId, audioFileExtension: "m4a", byteCount: digest.byteCount,
            sha256: transfer.sha256.isEmpty ? digest.sha256 : transfer.sha256.lowercased(),
            durationMs: transfer.durationMs, recordedAt: transfer.wallStart, anchor: nil
        )
        guard let receipt = try? inbox.receive(file: audioURL, metadata: metadata) else { return nil }
        guard receipt.confirmsDelivery else {
            return WatchMarginAnswer(receipt: receipt, outcome: .rejected, reason: "The recording arrived damaged. Send it again.")
        }
        // The Watch's clock, corrected by its measured offset; the raw time is kept as evidence (DESIGN section 4 point 8).
        let corrected = LiveSessionWatchSessions.phoneTime(transfer.wallStart, clock: transfer.clock)
        let offset = transfer.clock.flatMap { $0.isFresh(at: transfer.wallStart) ? $0.offset : nil }
        let incoming = LiveSessionFiling.Incoming(
            marginId: transfer.marginId, markedAt: transfer.wallStart, clockOffset: offset, sessionId: transfer.sessionId,
            itemTarget: transfer.itemTarget
        )
        let decision = LiveSessionFiling.decide(incoming, sessions: candidates(), deletions: deletions, playerRuns: playerRuns, now: now)
        let hint = LiveSessionFiling.playingThen(for: incoming, decision: decision, playerRuns: playerRuns)
        switch decision {
        case .alreadyFiled:
            try? inbox.markIncorporated(captureId)
            dropStoredAudio(inbox, captureId)
            return alreadyFiledAnswer(receipt, marginId: transfer.marginId)
        case let .rejected(reason):
            try? inbox.markIncorporated(captureId)
            dropStoredAudio(inbox, captureId)
            return WatchMarginAnswer(receipt: receipt, outcome: .rejected, reason: reason.words)
        default:
            break
        }
        // The recording goes where the app's Margin recorder keeps spoken Margins, before the Margin is filed.
        guard let stored = inbox.audioURL(captureId), let destination = recordingURL(for: transfer.audioPath) else { return nil }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: stored, to: destination)
        } catch {
            return nil
        }
        if case let .playerItem(itemId, positionMs) = decision {
            // Not cleared and not answered yet: the app writes it onto the item, or files it by the rest of the rule, and
            // only then calls `completePlacement`. If the app ends first, the recording is still here for the next pass.
            pass.placements.append(PlayerPlacement(
                marginId: transfer.marginId, itemId: itemId, positionMs: positionMs, markedAt: corrected.time,
                audioPath: transfer.audioPath, durationMs: transfer.durationMs, spokenOn: "watch",
                pending: PendingWatchCapture(captureId: captureId, receipt: receipt, landedStem: audioURL.deletingPathExtension().path),
                aimedAtItem: transfer.itemTarget != nil, playingThen: hint
            ))
            return nil
        }
        var margin = LiveSessionMargin(id: transfer.marginId, text: "", markedAt: corrected.time)
        margin.deviceMarkedAt = transfer.wallStart
        margin.clockNote = corrected.note
        margin.audioPath = transfer.audioPath
        margin.durationMs = transfer.durationMs
        margin.spokenOn = "watch"
        guard let session = try? place(margin, by: decision, playingThen: hint) else { return nil }
        pass.changed = true
        pass.filed.append(FiledMargin(marginId: transfer.marginId, audioPath: transfer.audioPath))
        try? inbox.markIncorporated(captureId)
        dropStoredAudio(inbox, captureId)
        return WatchMarginAnswer(
            receipt: receipt, outcome: .filed, sessionId: session.id, filedIn: Self.name(of: session),
            positionMs: session.margins.first { $0.id == transfer.marginId }?.sessionOffsetMs
        )
    }

    /// Puts a Margin where `decision` says, and saves that session. Returns it, or nil when the decision files nothing.
    /// `playingThen`, when given, is kept on the Margin (#4233 Design 2.9.1); one the Margin already carries is kept.
    private func place(
        _ margin: LiveSessionMargin, by decision: LiveSessionFiling.Decision, newQuickId: String? = nil,
        playingThen: LiveSessionPlayingThen? = nil
    ) throws -> LiveSession? {
        var target: LiveSession
        var placed = margin
        if placed.playingThen == nil { placed.playingThen = playingThen }
        switch decision {
        case let .session(id, placement):
            guard let session = sessions()[id] else { return nil }
            target = session
            if placement == .afterEnd { placed.filingNote = LiveSessionFiling.afterEndNote }
        case let .joinQuick(id):
            guard let session = sessions()[id] else { return nil }
            target = session
        case let .newNamedSession(id):
            // Its start is still on its way from the Watch (the file came first); the start fills it in.
            target = LiveSession(id: id, kind: .other, startedAt: margin.markedAt, endedAt: margin.markedAt)
            target.ownerDevice = WatchDevice.watch.rawValue
            target.endReason = LiveSessionWatchSessions.EndReason.placeholder.rawValue
        case .newQuick:
            target = LiveSessionFiling.quickSession(id: newQuickId ?? "quick-\(makeId())", holding: placed)
        case .alreadyFiled, .rejected, .playerItem:
            return nil
        }
        let before = target
        target.add(placed)
        noteUnseen(from: before, to: target)
        try persist([target])
        return target
    }

    private func tidy(now: Date, pass: inout Pass) {
        let all = Array(sessions().values)
        let (kept, removed) = LiveSessionFiling.tidy(all, now: now)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = kept.filter { byId[$0.id] != $0 }
        guard !changed.isEmpty || !removed.isEmpty else { return }
        for session in changed { if let before = byId[session.id] { noteUnseen(from: before, to: session) } }
        for id in removed {
            cache?[id] = nil
            collection?.remove(id: id)
            unseenMargins[id] = nil
            unseenTranscripts[id] = nil
        }
        try? persist(changed)
        pass.changed = true
    }

    private func candidates() -> [LiveSessionFiling.Candidate] {
        sessions().values.map(LiveSessionFiling.Candidate.init)
    }

    private func alreadyFiledAnswer(_ receipt: WatchMarginReceipt, marginId: String) -> WatchMarginAnswer {
        let holder = sessions().values.first { $0.margins.contains { $0.id == marginId } }
        return WatchMarginAnswer(receipt: receipt, outcome: .alreadyFiled, sessionId: holder?.id, filedIn: holder.map(Self.name(of:)))
    }

    static func title(of session: LiveSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty else { return title }
        return session.isQuick == true ? "Quick session" : "\(session.kind.label) session"
    }

    static func name(of session: LiveSession) -> String {
        session.isQuick == true ? "a quick session" : title(of: session)
    }

    func openWatchInbox() -> WatchMarginInbox? {
        if let watchInbox { return watchInbox }
        guard let receivedDirectory else { return nil }
        watchInbox = try? WatchMarginInbox(directory: receivedDirectory)
        return watchInbox
    }

    /// The filed copy lives where spoken Margins live; the inbox keeps only its record, which is what answers a repeat.
    private func dropStoredAudio(_ inbox: WatchMarginInbox, _ captureId: String) {
        if let url = inbox.audioURL(captureId) { try? FileManager.default.removeItem(at: url) }
    }

    func persist(_ changed: [LiveSession]) throws {
        guard let collection else { return }
        var all = sessions()
        for session in changed {
            try collection.save(session)
            all[session.id] = session
        }
        cache = all
        try collection.writeLegacyMirror(Array(all.values))
    }

    // MARK: Margins the screen hasn't seen

    func noteUnseen(from before: LiveSession, to after: LiveSession) {
        let old = Dictionary(before.margins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for margin in after.margins {
            if let earlier = old[margin.id] {
                if earlier.text != margin.text, !margin.text.isEmpty { unseenTranscripts[after.id, default: [:]][margin.id] = margin.text }
            } else {
                unseenMargins[after.id, default: [:]][margin.id] = margin
            }
        }
        // A Margin that moved out (tidying) must not come back with a stale screen save.
        for id in Set(old.keys).subtracting(after.margins.map(\.id)) { unseenMargins[after.id]?[id] = nil }
    }

    /// The screen's copy with anything this worker filed that it hasn't taken in yet.
    private func keepingUnseen(in session: LiveSession) -> LiveSession {
        var merged = session
        if let lifecycle = unseenLifecycle[session.id] {
            if Lifecycle(session) == lifecycle {
                unseenLifecycle[session.id] = nil // the screen has it
            } else {
                lifecycle.apply(to: &merged)
                for index in merged.margins.indices {
                    merged.margins[index].sessionOffsetMs = max(0, Int((merged.margins[index].markedAt.timeIntervalSince(merged.startedAt) * 1_000).rounded()))
                }
            }
        }
        for (id, margin) in unseenMargins[session.id] ?? [:] {
            if merged.margins.contains(where: { $0.id == id }) {
                unseenMargins[session.id]?[id] = nil
            } else {
                merged.add(margin)
            }
        }
        for (id, text) in unseenTranscripts[session.id] ?? [:] {
            guard let index = merged.margins.firstIndex(where: { $0.id == id }) else { continue }
            if merged.margins[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                merged.setTranscript(text, forMarginId: id)
            } else {
                unseenTranscripts[session.id]?[id] = nil // the screen has words for it: its own or these
            }
        }
        merged.margins.sort { $0.markedAt < $1.markedAt }
        return merged
    }

    /// Moves a received file into the landing folder, with its metadata beside it. Runs on WatchConnectivity's delegate
    /// queue, before iOS deletes the file when the delegate call returns, so it can't wait for the actor. The move is
    /// one rename inside the app's container.
    public nonisolated func storeIncoming(fileAt url: URL, transfer: WatchMarginTransfer) throws {
        guard let inbox = inboxDirectory else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: transfer.audioPath).deletingPathExtension().lastPathComponent
        let audio = inbox.appending(path: "\(stem).m4a")
        if fileManager.fileExists(atPath: audio.path) { try fileManager.removeItem(at: audio) }
        try fileManager.moveItem(at: url, to: audio)
        try JSONEncoder().encode(transfer).write(to: inbox.appending(path: "\(stem).json"), options: .atomic)
    }

    // MARK: Margins moved onto an item (#4233 Design 2.9.4)

    /// What taking moved Margins out of a session did.
    public struct MovedRemoval: Equatable, Sendable {
        /// The session as it is now, or nil when the move emptied it and it went.
        public var session: LiveSession?
        /// True when the session went: a quick session the listener never renamed, left empty.
        public var removedSession: Bool
        /// The Margins that were in the session and are not now.
        public var removedIds: [String]
    }

    /// Takes Margins that are now on an item out of session `sessionId`, in one write, after `LiveMarginMove.execute`
    /// wrote the item side. Their ids go into `deletions.json`, so a late Watch copy of one is refused (filing's step 1),
    /// but the session's own span does not: a quick session the move empties goes the way `tidy` removes one, so a later
    /// Margin captured in its span still files, and Undo can bring the session back. Recording files are never deleted.
    /// Returns nil when no stored session has that id.
    public func removeMovedMargins(ids: Set<String>, fromSession sessionId: String) throws -> MovedRemoval? {
        sessions() // loads the deletions too
        guard let collection, let before = sessions()[sessionId] else { return nil }
        var after = before
        after.margins.removeAll { ids.contains($0.id) }
        let removedIds = before.margins.map(\.id).filter { ids.contains($0) }
        let previousDeletions = deletions
        deletions.marginIds.formUnion(ids)
        let goes = after.margins.isEmpty && LiveMarginMove.removesSession(before, movingIds: ids)
        do {
            if goes {
                var all = sessions()
                all[sessionId] = nil
                try collection.writeLegacyMirror(Array(all.values))
                collection.remove(id: sessionId)
                cache = all
                unseenMargins[sessionId] = nil
                unseenTranscripts[sessionId] = nil
            } else {
                after.fitQuickSpan()
                noteUnseen(from: before, to: after)
                try persist([after])
            }
        } catch {
            deletions = previousDeletions
            throw error
        }
        try? collection.saveDeletions(deletions)
        for key in unseenMargins.keys { for id in ids { unseenMargins[key]?[id] = nil } }
        return MovedRemoval(session: goes ? nil : after, removedSession: goes, removedIds: removedIds)
    }

    /// Why Undo couldn't put Margins back into their session.
    public enum RestoreOutcome: Equatable, Sendable {
        /// They are in the session again (or already were). The session as stored now.
        case restored(LiveSession)
        /// The session became a Library item meanwhile.
        case savedAsNotes
        /// The listener discarded the session meanwhile.
        case discarded
    }

    /// Undo of a move, live side: puts `margins` back into `session` (the session as it was before the move) with their
    /// ids, recordings, times, position lines and filing notes, and takes their ids out of `deletions.json`. A session the
    /// move or `tidy` removed is made again from `session`, holding only these Margins. A Margin already back in a session
    /// is skipped, so a second Undo restores nothing twice. Refused, with nothing changed, when the session was saved as
    /// notes or discarded meanwhile.
    public func restoreMovedMargins(_ margins: [LiveSessionMargin], into session: LiveSession) throws -> RestoreOutcome {
        sessions() // loads the deletions too
        guard collection != nil else { return .restored(session) }
        if deletions.deletedSession(session.id) { return .discarded }
        let stored = sessions()[session.id]
        if stored?.savedItemId != nil { return .savedAsNotes }
        var target: LiveSession
        if let stored {
            target = stored
        } else {
            target = session
            target.margins = []
        }
        let before = target
        let elsewhere = Set(sessions().values.flatMap { $0.margins.map(\.id) })
        let returning = margins.filter { !elsewhere.contains($0.id) }
        guard !returning.isEmpty else { return .restored(stored ?? session) }
        let previousDeletions = deletions
        deletions.marginIds.subtract(returning.map(\.id))
        for margin in returning { target.add(margin) }
        if stored == nil { noteUnseen(from: LiveSession(id: target.id, startedAt: target.startedAt), to: target) } else {
            noteUnseen(from: before, to: target)
        }
        do {
            try persist([target])
        } catch {
            deletions = previousDeletions
            throw error
        }
        try? collection?.saveDeletions(deletions)
        return .restored(target)
    }

    /// Finishes a move the app was stopped in the middle of (Design 2.9.4 step 3): the item side was written, the live
    /// side not yet. `liveMarginIds` are the live ids of the moved Margins still active on items (the origin records'
    /// `liveMarginId`, which the app reads from the database). Each of them still in an unsaved session is taken out as
    /// the move would have. Returns the sessions that changed or went.
    @discardableResult
    public func reconcileMovedMargins(liveMarginIds: Set<String>) -> [String] {
        guard !liveMarginIds.isEmpty else { return [] }
        let holding = sessions().values
            .filter { $0.savedItemId == nil && $0.margins.contains { liveMarginIds.contains($0.id) } }
            .map(\.id)
            .sorted()
        var touched: [String] = []
        for sessionId in holding {
            let ids = Set(sessions()[sessionId]?.margins.map(\.id).filter { liveMarginIds.contains($0) } ?? [])
            if (try? removeMovedMargins(ids: ids, fromSession: sessionId)) != nil { touched.append(sessionId) }
        }
        return touched
    }
}
