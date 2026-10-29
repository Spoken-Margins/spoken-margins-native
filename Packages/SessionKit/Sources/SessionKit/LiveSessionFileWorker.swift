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
            let decision = LiveSessionFiling.decide(
                .init(marginId: id, markedAt: time), sessions: candidates(), deletions: deletions, playerRuns: playerRuns, now: now
            )
            if case let .playerItem(itemId, positionMs) = decision {
                pass.placements.append(PlayerPlacement(marginId: id, itemId: itemId, positionMs: positionMs, markedAt: time))
                continue
            }
            if (try? place(margin, by: decision)) != nil { pass.changed = true }
        }
        tidy(now: now, pass: &pass)
        return pass
    }

    /// A Margin the player's item couldn't take files into a session instead, by the rest of the rule.
    @discardableResult
    public func fileAsQuick(_ placement: PlayerPlacement, now: Date = Date()) -> Bool {
        sessions()
        var margin = LiveSessionMargin(id: placement.marginId, text: "", markedAt: placement.markedAt, isBlindMark: placement.audioPath == nil)
        margin.audioPath = placement.audioPath
        margin.durationMs = placement.durationMs
        margin.spokenOn = placement.spokenOn
        let decision = LiveSessionFiling.decide(
            .init(marginId: placement.marginId, markedAt: placement.markedAt, allowsPlayerItem: false),
            sessions: candidates(), deletions: deletions, playerRuns: [], now: now
        )
        guard (try? place(margin, by: decision)) != nil else { return false }
        var pass = Pass()
        tidy(now: now, pass: &pass)
        return true
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
        let decision = LiveSessionFiling.decide(
            .init(marginId: transfer.marginId, markedAt: transfer.wallStart, clockOffset: offset, sessionId: transfer.sessionId),
            sessions: candidates(), deletions: deletions, playerRuns: playerRuns, now: now
        )
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
            pass.placements.append(PlayerPlacement(
                marginId: transfer.marginId, itemId: itemId, positionMs: positionMs, markedAt: corrected.time,
                audioPath: transfer.audioPath, durationMs: transfer.durationMs, spokenOn: "watch"
            ))
            try? inbox.markIncorporated(captureId)
            dropStoredAudio(inbox, captureId)
            return WatchMarginAnswer(receipt: receipt, outcome: .filed, filedIn: "what was playing", positionMs: positionMs)
        }
        var margin = LiveSessionMargin(id: transfer.marginId, text: "", markedAt: corrected.time)
        margin.deviceMarkedAt = transfer.wallStart
        margin.clockNote = corrected.note
        margin.audioPath = transfer.audioPath
        margin.durationMs = transfer.durationMs
        margin.spokenOn = "watch"
        guard let session = try? place(margin, by: decision) else { return nil }
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
    private func place(_ margin: LiveSessionMargin, by decision: LiveSessionFiling.Decision) throws -> LiveSession? {
        var target: LiveSession
        var placed = margin
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
            target = LiveSessionFiling.quickSession(id: "quick-\(makeId())", holding: placed)
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
}
