import Foundation

/// The items a listener lined up to play one after another (#1990). It holds item ids only, in order, and lives in its
/// own small file, not the database, so an older build still opens the database as it was.
public struct PlayQueue: Codable, Equatable, Sendable {
    public private(set) var itemIds: [String]

    public init(itemIds: [String] = []) {
        var seen = Set<String>()
        self.itemIds = itemIds.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { itemIds.isEmpty }
    public var count: Int { itemIds.count }
    public func contains(_ itemId: String) -> Bool { itemIds.contains(itemId) }

    /// Puts `itemId` first. An item already queued moves; it never appears twice.
    public mutating func playNext(_ itemId: String) {
        itemIds.removeAll { $0 == itemId }
        itemIds.insert(itemId, at: 0)
    }

    /// Puts `itemIds` first, in the order given (#3769, Play all). An item already queued moves forward to its place among
    /// them, one that appears twice in `itemIds` counts once, and everything else keeps its order behind them. Called twice
    /// with the same ids, it leaves the queue as it was.
    public mutating func playNext(contentsOf itemIds: some Sequence<String>) {
        var seen = Set<String>()
        let front = itemIds.filter { seen.insert($0).inserted }
        guard !front.isEmpty else { return }
        self.itemIds.removeAll { seen.contains($0) }
        self.itemIds.insert(contentsOf: front, at: 0)
    }

    /// Puts each of `itemIds` last, in the order given (#4720, Add to Queue). An item already queued keeps its place.
    /// Returns how many were added, for the banner's count.
    @discardableResult
    public mutating func append(contentsOf itemIds: some Sequence<String>) -> Int {
        let before = self.itemIds.count
        for itemId in itemIds { append(itemId) }
        return self.itemIds.count - before
    }

    /// Puts `itemId` last. An item already queued keeps its place.
    public mutating func append(_ itemId: String) {
        guard !itemIds.contains(itemId) else { return }
        itemIds.append(itemId)
    }

    public mutating func remove(_ itemId: String) {
        itemIds.removeAll { $0 == itemId }
    }

    /// Takes every one of `itemIds` out, as a permanent delete does for the items it removes (#4227). Order of the rest
    /// is kept.
    public mutating func removeAll(in itemIds: some Collection<String>) {
        let gone = Set(itemIds)
        guard !gone.isEmpty else { return }
        self.itemIds.removeAll { gone.contains($0) }
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.compactMap { itemIds.indices.contains($0) ? itemIds[$0] : nil }
        let before = source.filter { $0 < destination }.count
        var rest = itemIds
        for index in source.sorted(by: >) where rest.indices.contains(index) { rest.remove(at: index) }
        rest.insert(contentsOf: moving, at: min(max(destination - before, 0), rest.count))
        itemIds = rest
    }

    public mutating func clear() {
        itemIds.removeAll()
    }

    /// Drops queued items that no longer exist. The queue screen does this before it reorders, so the rows it shows
    /// and the queue it edits are the same list.
    public mutating func prune(isAvailable: (String) -> Bool) {
        itemIds.removeAll { !isAvailable($0) }
    }

    /// The item `popNext(isAvailable:)` would take, without taking it (#3914).
    public func peekNext(isAvailable: (String) -> Bool) -> String? {
        itemIds.first(where: isAvailable)
    }

    /// The queued item the playback screen's "Next in queue" would start (#3914): the next one that still exists, unless it
    /// is the item already playing or being started. It is drawn only while this is non-nil and it is the answer the tap is
    /// checked against, so a second tap after the item started (it left the queue, so the peek is now the one after it)
    /// and a tap in the moment the queue advanced by itself both find a different answer and do nothing.
    public func nextToStart(playing: String?, starting: String?, isAvailable: (String) -> Bool) -> String? {
        guard let next = peekNext(isAvailable: isAvailable), next != playing, next != starting else { return nil }
        return next
    }

    /// Takes the next item that still exists. Items that were deleted since they were queued are dropped on the way,
    /// so one of them never jams the queue.
    public mutating func popNext(isAvailable: (String) -> Bool) -> String? {
        while !itemIds.isEmpty {
            let next = itemIds.removeFirst()
            if isAvailable(next) { return next }
        }
        return nil
    }
}

/// Which queued ids belong to no item at all, so a delete that was interrupted (the app quit after the rows went and
/// before the queue was written) is made good at the next launch (#4227). An id stays unless it is missing from both
/// the stored ids and what the app knows right now: an item added or imported after the stored ids were read has no
/// stored id in this answer but is on the app's lists, and is never dropped.
public enum PlayQueueOrphans {
    /// `storedIds` is every item id in the Library, trashed and quarantined ones included (an item in Recently Deleted
    /// can still be restored, so its place stays). `knownNow` is the ids the app's lists hold at the moment of the check.
    public static func orphans(in queue: PlayQueue, storedIds: Set<String>, knownNow: Set<String>) -> [String] {
        queue.itemIds.filter { !storedIds.contains($0) && !knownNow.contains($0) }
    }
}

/// When the queue moves on: the moment a session reaches its end, once (#1990).
public enum PlayQueueAdvance {
    /// True on the edge into `.finished` for the same session. A finished session that was only restored (a
    /// different or missing previous session) and a snapshot that stays finished never advance, so the queue cannot
    /// repeat for one finish (the #2626 class).
    public static func shouldAdvance(from previous: SessionSnapshot, to current: SessionSnapshot) -> Bool {
        guard current.phase == .finished, previous.phase != .finished,
              let itemId = current.itemId, previous.itemId == itemId,
              let sessionId = current.sessionId, previous.sessionId == sessionId else { return false }
        return true
    }

    /// What the queue does at a snapshot change, for the advance and for Diagnostics (#5358). `nil` for the ordinary
    /// change that is no end at all, so Diagnostics gets one line per end, never one per tick.
    ///
    /// - `advance`: the finish edge with a queued item ready, and no sleep timer running.
    /// - `skipped(.sleepTimer)`: the finish edge while a sleep timer runs; the listener asked for the audio to stop.
    /// - `skipped(.queueEmpty)`: the finish edge with nothing available in the queue.
    /// - `skipped(.noFinishEdge)`: the same session stopped at its end (paused, at the end percent) without moving
    ///   into `.finished`, so the queue could not see a finish. This was the #5358 skip to the end of an article.
    public static func decision(
        from previous: SessionSnapshot, to current: SessionSnapshot, sleepTimerActive: Bool, queueHasNext: Bool
    ) -> Decision? {
        if shouldAdvance(from: previous, to: current) {
            if sleepTimerActive { return .skipped(.sleepTimer) }
            return queueHasNext ? .advance : .skipped(.queueEmpty)
        }
        guard previous.status.isPlaybackActive, current.status == .paused, current.phase != .finished,
              current.currentPlaybackProgressPercent >= ItemFinishedRule.atEndPercent,
              let sessionId = current.sessionId, previous.sessionId == sessionId,
              let itemId = current.itemId, previous.itemId == itemId,
              current.targetId == previous.targetId else { return nil }
        return .skipped(.noFinishEdge)
    }

    public enum Decision: Equatable, Sendable {
        case advance
        case skipped(SkipReason)

        /// The Diagnostics fields: the outcome and, for a skip, its reason. No ids or titles.
        public var diagnosticFields: [String: String] {
            switch self {
            case .advance: return ["outcome": "advanced"]
            case .skipped(let reason): return ["outcome": "skipped", "reason": reason.rawValue]
            }
        }
    }

    public enum SkipReason: String, Equatable, Sendable {
        case sleepTimer = "sleep_timer"
        case queueEmpty = "queue_empty"
        case noFinishEdge = "no_finish_edge"
        /// The queued item was taken off the queue but did not start (recording a Margin, an episode that can't
        /// play offline). Recorded by the app after its start, not by `decision`.
        case startRefused = "start_refused"
    }
}

/// The queue's file. A missing or unreadable file is an empty queue, never an error the listener sees.
public struct PlayQueueStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> PlayQueue {
        guard let data = try? Data(contentsOf: fileURL),
              let queue = try? JSONDecoder().decode(PlayQueue.self, from: data) else { return PlayQueue() }
        return PlayQueue(itemIds: queue.itemIds)
    }

    public func save(_ queue: PlayQueue) throws {
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(queue).write(to: fileURL, options: .atomic)
    }
}
