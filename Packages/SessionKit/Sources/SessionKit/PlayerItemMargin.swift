import Foundation

/// Files a Margin that came from somewhere else (the Watch, #2542; the Lock Screen, #3203) onto the item our own player
/// was playing, at the place it was taken, as an ordinary Margin of that item's session (`docs/design/live-sessions/
/// DESIGN.md` section 2 point 12: "It does not make a quick session").
///
/// A Margin belongs to a session at a place, and the engine builds its anchor from the session's saved place. So this
/// moves the saved place to the Margin's time, writes the Margin through the engine's own path (spoken, with a recorder
/// that hands back the file already recorded, as `LiveSessionMarginPlacer` does; or written, for a Mark), and then puts
/// the whole session back as it was, resume point and `updatedAt` included. Sessions are ordered by `updatedAt` and the
/// app reopens the newest resumable one, so the item still resumes exactly where the listener left it. Whatever is
/// wrong, the session is put back before the error is thrown, and the caller files the Margin another way
/// (`LiveSessionFileWorker.fileAsQuick`).
///
/// It runs on an item whose session keeps a media clock (an episode, an audio file, a narrated article with a
/// transcript), and on an article that plays its publisher's recording (#547). That article's session is stored in
/// article form, at a text place, so the recording's time is turned into the text place the recording's map gives for
/// it, and the engine resumes the session as the recording there, as it does when the listener opens the article. Any
/// other item throws `unsupportedTarget`. The app runs it on the main actor, in order, a few milliseconds long.
public enum PlayerItemMargin {
    public enum Failure: Error, Equatable {
        case itemNotFound
        /// The listener has not started the item, so there is no session to write on.
        case noSession
        /// The session has no media clock, so a media time means nothing on it.
        case unsupportedTarget
        /// `placeSpoken` was given no recording; a Mark goes through `placeMark`.
        case noRecording
        case notWritten
    }

    /// Saves a spoken Margin whose recording is `audioPath`, taken at `markedAt`, at `mediaTimeMs` on `itemId`.
    @discardableResult
    public static func placeSpoken(
        audioPath: String?,
        atMediaTimeMs mediaTimeMs: Int,
        markedAt: Date,
        itemId: String,
        repository: SessionRepository & StructuredDocumentRepository
    ) throws -> Interjection {
        guard let audioPath, !audioPath.isEmpty else { throw Failure.noRecording }
        let target = try Target(itemId: itemId, mediaTimeMs: mediaTimeMs, repository: repository)
        // A retry after the first try got as far as the store: the Margin is already there, so never write a second copy.
        if let existing = (try? repository.loadInterjections(sessionId: target.original.id))?.first(where: { $0.audioPath == audioPath }) {
            return existing
        }
        let recorder = PrerecordedMarginRecorder()
        recorder.audioPath = audioPath
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "player-item-spoken-margin", displayName: "Player item spoken Margin",
                capabilities: ["interjection": ["record_audio"]]
            ),
            repository: repository,
            recorder: recorder,
            now: { markedAt }
        )
        return try write(on: target, repository: repository, matching: { $0.audioPath == audioPath }) {
            try engine.inspectSession(sessionId: target.original.id)
            _ = try engine.beginInterjection()
            _ = try engine.finishInterjection(audioRef: audioPath, resumesSource: false)
        }
    }

    /// Saves a Lock Screen Mark (#3203), taken at `markedAt`, at `mediaTimeMs` on `itemId`.
    ///
    /// A Mark has no recording and no words, so on the item it is an ordinary written Margin whose words say plainly
    /// what it is, where and when (`markWords`), the way a voice Margin without words travels (owner, 2026-10-30). The
    /// listener can replace the words like any written Margin's. No storage and no packet key change: Build 29 reads it
    /// as a written Margin, and every packet reader since needs the words a Margin carries (#304).
    @discardableResult
    public static func placeMark(
        atMediaTimeMs mediaTimeMs: Int,
        markedAt: Date,
        itemId: String,
        repository: SessionRepository & StructuredDocumentRepository,
        timeZone: TimeZone = .current
    ) throws -> Interjection {
        let target = try Target(itemId: itemId, mediaTimeMs: mediaTimeMs, repository: repository)
        let words = markWords(
            mediaTimeMs: target.isArticle ? nil : target.timeMs, itemTitle: target.item.title, markedAt: markedAt, timeZone: timeZone
        )
        // The store keeps a Margin's date to the second, so a written Margin of the same second with these same words
        // is this Mark, already placed: a second call writes no second copy. (The app drains each Mark from its queue
        // before filing it, so this guards a repeated call, not a queue retry.)
        let second = markedAt.timeIntervalSince1970.rounded(.down)
        func isThisMark(_ margin: Interjection) -> Bool {
            margin.captureKind == .written && margin.transcript == words
                && margin.createdAt.timeIntervalSince1970.rounded(.down) == second
        }
        if let existing = (try? repository.loadInterjections(sessionId: target.original.id))?.first(where: isThisMark) {
            return existing
        }
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "player-item-mark", displayName: "Player item Mark", capabilities: [:]),
            repository: repository,
            now: { markedAt }
        )
        return try write(on: target, repository: repository, matching: isThisMark) {
            try engine.inspectSession(sessionId: target.original.id)
            let capture = try engine.beginWrittenInterjection()
            do {
                try engine.saveWrittenInterjection(captureId: capture.id, text: words)
            } catch {
                _ = try? engine.cancelWrittenInterjection(captureId: capture.id)
                throw error
            }
        }
    }

    /// The longest item title a Mark's words quote, in characters, ellipsis included.
    public static let markTitleCharacterLimit = 80

    /// `Mark at 12:34 in “Title”, from the Lock Screen on 4 Nov 2026`. Without a media time (an article) the "at" part
    /// is left out. The words open with "Mark", so neither the listener nor a friend reads them as anyone's own.
    public static func markWords(mediaTimeMs: Int?, itemTitle: String?, markedAt: Date, timeZone: TimeZone = .current) -> String {
        var text = "Mark"
        if let mediaTimeMs { text += " at \(LiveSessionPositionMap.clock(mediaTimeMs))" }
        let line = (itemTitle ?? "").precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let title = line.count > markTitleCharacterLimit
            ? String(line.prefix(markTitleCharacterLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : line
        if !title.isEmpty { text += " in “\(title)”" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.day, .month, .year], from: markedAt)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        text += ", from the Lock Screen on \(day.day ?? 1) \(months[((day.month ?? 1) - 1 + 12) % 12]) \(day.year ?? 0)"
        return text
    }

    /// Whether `session` can hold a Margin placed by media time: an item with a media clock, or an article (whose
    /// publisher recording may have been playing). `withdraw` looks only in these.
    static func takesPlacedMargins(_ session: Session) -> Bool {
        switch session.currentTargetType {
        case .transcriptBackedMedia, .browserOwnedMedia, .itemTextTTS: true
        default: false
        }
    }

    /// The listener deleted the Margin on the Watch after the phone had already put it on an item: marks every Margin
    /// recorded at `audioPath` deleted, the way deleting a Margin in the app does (its status, nothing else), and
    /// returns the item ids it touched. `sessions` are the sessions to look in. `markDeleted` makes the change; the app
    /// passes `SQLiteSessionStore.updateInterjection`, so it is one transaction and cannot erase another thread's edit
    /// of the same Margin (#2509). A Margin already deleted is left alone, and a retry of `placeSpoken` for the same
    /// recording finds the deleted copy and writes no second one.
    @discardableResult
    public static func withdraw(
        audioPath: String,
        in sessions: [Session],
        repository: SessionRepository,
        markDeleted: (_ margin: Interjection) throws -> Bool
    ) -> [String] {
        var touched: [String] = []
        for session in sessions {
            guard takesPlacedMargins(session), let margins = try? repository.loadInterjections(sessionId: session.id) else { continue }
            for margin in margins where margin.audioPath == audioPath && margin.status != "deleted" {
                if (try? markDeleted(margin)) == true, !touched.contains(session.itemId) { touched.append(session.itemId) }
            }
        }
        return touched
    }

    // MARK: Where the Margin goes

    /// The item, its session as it was, and that session moved to the Margin's place.
    private struct Target {
        let item: Item
        let original: Session
        let moved: Session
        /// The Margin's media time, kept inside the media.
        let timeMs: Int
        /// True for an article playing its publisher's recording: the place is a text place.
        let isArticle: Bool

        init(itemId: String, mediaTimeMs: Int, repository: SessionRepository & StructuredDocumentRepository) throws {
            guard let item = try? repository.loadItem(id: itemId), item.deletedAt == nil else { throw Failure.itemNotFound }
            guard let original = StoredSessionMargin.targetSession(in: try repository.loadSessions(itemId: itemId)) else {
                throw Failure.noSession
            }
            func clamped(_ durationMs: Int?) -> Int {
                durationMs.map { min(max(0, mediaTimeMs), max(0, $0 - 1)) } ?? max(0, mediaTimeMs)
            }
            var moved = original
            switch original.currentTargetType {
            case .transcriptBackedMedia, .browserOwnedMedia:
                timeMs = clamped(item.media?.durationMs)
                moved.position.mediaTimeMs = timeMs
                isArticle = false
            case .itemTextTTS:
                // Only an article playing its publisher's recording has a media time; one read with on-device speech
                // reports none, so the player keeps no run for it (`PlayerRunRecorder`).
                guard original.phase == .itemPlayback,
                      let record = try? (repository as? any PublisherAudioRepository)?.loadPublisherAudio(itemId: itemId),
                      let plan = PublisherAudioPlayback.plan(for: item, record: record) else { throw Failure.unsupportedTarget }
                timeMs = clamped(plan.playingMedia.durationMs)
                let offset = PreparedNarrationFallback.textOffset(mediaTimeMs: timeMs, timeline: plan.timeline)
                moved.position = Position(charOffset: max(0, min(offset, item.text?.count ?? 0)), chapterId: nil)
                isArticle = true
            default:
                throw Failure.unsupportedTarget
            }
            self.item = item
            self.original = original
            self.moved = moved
        }
    }

    /// Moves the session to the Margin's place, runs `body` (which loads it into an engine and takes the engine's own
    /// Margin path), and puts the session back
    /// whatever happened: the resume point, the percent, the phase and `updatedAt`. Returns the new Margin.
    private static func write(
        on target: Target,
        repository: SessionRepository & StructuredDocumentRepository,
        matching isTheMargin: (Interjection) -> Bool,
        _ body: () throws -> Void
    ) throws -> Interjection {
        let sessionId = target.original.id
        let before = Set((try? repository.loadInterjections(sessionId: sessionId))?.map(\.id) ?? [])
        func written() -> Interjection? {
            (try? repository.loadInterjections(sessionId: sessionId))?.first { !before.contains($0.id) && isTheMargin($0) }
        }
        var failure: Error?
        do {
            try repository.saveSession(target.moved)
            try body()
        } catch {
            failure = error
        }
        try? repository.saveSession(target.original)
        // The engine stores the Margin before its last steps, so a throw after that still left it written. Report what
        // is in the store, so the caller never files a second copy of a Margin that is already on the item.
        if let saved = written() { return saved }
        throw failure ?? Failure.notWritten
    }
}
