import Foundation

/// A repository whose writes may run on another thread while the main thread reads it (SQLite, with its own
/// locking). `StreamedTurnCursorWriter` saves off the main thread only for such a repository; for any other it waits
/// for each write, so a plain in-memory repository is never written and read at once.
public protocol ConcurrentSessionRepository: SessionRepository {}

/// The cursor of a reply or summary heard through the streaming speech queue, saved off the main thread (#2509).
///
/// While a turn is spoken through the streaming queue, the app reports the cursor at each sentence it starts and on
/// every progress tick (about twice a second). Each report used to decode all of the session's turns and write the
/// Session row on the main thread. Now the engine moves the cursor in memory, using the turn's `Shape` from the last
/// write, and this writer saves the newest place on its own serial queue, then reads the turn again there, so the
/// next report clamps to the turn's current text. The engine's snapshot of the turn's progress reads the same copy
/// (`turn(for:)`) instead of decoding the turns again; a change the engine saves itself (`noteSaved`) is seen at once.
///
/// Durability: a report is queued at once and written within milliseconds. A burst of reports while a write runs
/// becomes one write of the newest. `flush()` waits until every queued write has landed. The engine flushes before
/// any other Session write, so an older place never lands over a newer one, and on the lifecycle sync the app runs
/// as it leaves the foreground, so the place is on disk before iOS suspends the app.
public final class StreamedTurnCursorWriter: @unchecked Sendable {
    /// What the cursor is clamped to: the turn's navigation text length and where its chapters start.
    public struct Shape: Equatable, Sendable {
        public struct ChapterStart: Equatable, Sendable {
            public var id: String
            public var startChar: Int
        }

        public var turnId: String
        public var textLength: Int
        /// A complete turn's text no longer grows, so a report past its end is clamped to it. A turn still being
        /// generated may have grown since this shape was read, so only a negative offset is corrected.
        public var isComplete: Bool
        public var chapterStarts: [ChapterStart]

        public init(turn: ConversationTurn) {
            turnId = turn.id
            textLength = Self.navigationText(for: turn).count
            isComplete = turn.status == "complete"
            chapterStarts = (turn.chapters ?? []).map { ChapterStart(id: $0.id, startChar: $0.startChar) }
        }

        /// The text a generated turn's cursor counts characters in: its body, else what is spoken for it.
        public static func navigationText(for turn: ConversationTurn) -> String {
            let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
            return playableText(for: turn)
        }

        /// What is spoken for a generated turn: the summary and the body, or whichever exists, else the raw text.
        public static func playableText(for turn: ConversationTurn) -> String {
            let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !summary.isEmpty, !text.isEmpty {
                return "\(summary)\n\n\(text)"
            }
            if !text.isEmpty { return text }
            if !summary.isEmpty { return summary }
            return turn.rawText ?? ""
        }

        /// Where a reported character offset lands, and the chapter it is in.
        public func position(charOffset: Int) -> (charOffset: Int, chapterId: String?) {
            var offset = max(0, charOffset)
            if isComplete { offset = min(offset, textLength) }
            return (offset, chapterStarts.last(where: { $0.startChar <= offset })?.id)
        }
    }

    private let repository: SessionRepository
    private let queue: DispatchQueue
    private let waitsForEachWrite: Bool
    private let lock = NSLock()
    private var pending: (session: Session, turnId: String)?
    private var drainScheduled = false
    /// The turn being heard and its newest known copy (nil until one is read).
    private var trackedTurnId: String?
    private var turn: ConversationTurn?
    /// Bumped by `seed` and `noteSaved`, so a read the queue began before them never replaces what they set.
    private var revision = 0
    private var failure: Error?
    private var writes = 0

    /// - Parameter queue: the serial queue writes run on. Tests pass their own, to hold it while they report.
    public init(
        repository: SessionRepository,
        queue: DispatchQueue = DispatchQueue(label: "SessionKit.StreamedTurnCursorWriter", qos: .userInitiated)
    ) {
        self.repository = repository
        self.queue = queue
        waitsForEachWrite = !(repository is ConcurrentSessionRepository)
    }

    /// The turn starting now, as read where it was claimed (nil when it isn't saved yet).
    public func seed(turnId: String, turn: ConversationTurn?) {
        lock.withLock {
            trackedTurnId = turnId
            self.turn = turn?.id == turnId ? turn : nil
            revision &+= 1
        }
    }

    /// The engine saved a turn: if it is the one being heard, this copy is now the newest.
    public func noteSaved(_ saved: ConversationTurn) {
        lock.withLock {
            guard trackedTurnId == saved.id else { return }
            turn = saved
            revision &+= 1
        }
    }

    /// The newest copy known of the turn being heard, nil for any other turn or before one is read.
    public func turn(for turnId: String) -> ConversationTurn? {
        lock.withLock { trackedTurnId == turnId ? turn : nil }
    }

    /// The newest shape known for `turnId`, nil when none is.
    public func shape(for turnId: String) -> Shape? {
        turn(for: turnId).map(Shape.init(turn:))
    }

    /// Queues `session`, already stamped, as the newest place of the streamed turn `turnId`.
    public func submit(_ session: Session, turnId: String) {
        let schedules = lock.withLock { () -> Bool in
            pending = (session, turnId)
            defer { drainScheduled = true }
            return !drainScheduled
        }
        if schedules {
            queue.async { [self] in drain() }
        }
        if waitsForEachWrite { flush() }
    }

    /// Returns once every queued write has landed.
    public func flush() {
        queue.sync {}
    }

    /// The error of a write that failed since the last call, so the caller can report it.
    public func takeFailure() -> Error? {
        lock.withLock {
            defer { failure = nil }
            return failure
        }
    }

    /// How many Session rows this writer has saved. For tests.
    public var writeCount: Int { lock.withLock { writes } }

    private func drain() {
        let next = lock.withLock { () -> (session: Session, turnId: String)? in
            defer {
                pending = nil
                drainScheduled = false
            }
            return pending
        }
        guard let next else { return }
        do {
            try repository.saveSession(next.session)
            let readFrom = lock.withLock { () -> Int in
                writes += 1
                return revision
            }
            let fresh = try repository.loadTurns(sessionId: next.session.id).first(where: { $0.id == next.turnId })
            lock.withLock {
                // Only the turn still being heard, and only if nothing newer was seeded or saved during the read.
                guard trackedTurnId == next.turnId, revision == readFrom, let fresh else { return }
                turn = fresh
            }
        } catch {
            lock.withLock { failure = error }
        }
    }
}
