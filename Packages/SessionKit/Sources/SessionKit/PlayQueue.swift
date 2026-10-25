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

    /// Puts `itemId` last. An item already queued keeps its place.
    public mutating func append(_ itemId: String) {
        guard !itemIds.contains(itemId) else { return }
        itemIds.append(itemId)
    }

    public mutating func remove(_ itemId: String) {
        itemIds.removeAll { $0 == itemId }
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
