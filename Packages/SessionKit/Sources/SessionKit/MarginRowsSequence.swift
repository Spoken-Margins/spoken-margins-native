import Foundation

/// Orders every writer of the Margins list (#2505) so a read that ran off the main thread never publishes over a
/// newer change.
///
/// The list has two kinds of writer. Reads (every item's rows, or one item's) run off the main thread and publish
/// when they land. Changes (a star, a note, a removed item, a full rebuild on the main thread) apply at once. Every
/// read and change takes a number from one clock. When a read lands, `finish` compares what happened since it began:
///
/// - `.drop`: a newer read of the same scope already began, or a full list read after it was published. That newer
///   result holds everything this read knew.
/// - `.rerun`: a change, or a newer read's published rows, touched this read's scope after it began. Publishing would
///   undo that change, so the caller reads again.
/// - `.publish`: nothing newer touched its scope.
///
/// A published read counts as a change made when its read began, not when it landed, because that is how fresh its
/// rows are: a one-item read that began before a full read is already inside the full read's rows.
///
/// A dropped read's caller may be awaited (pull to refresh, a test), and the newer read that superseded it may not
/// have published yet. `end` and `isWaitingOnNewerRead` let the caller hold its return until that newer read is done,
/// so an awaited refresh never comes back having published nothing (#2766).
public struct MarginRowsSequence: Sendable {
    public enum Scope: Hashable, Sendable {
        case all
        case item(String)
    }

    public struct Read: Equatable, Sendable {
        public let scope: Scope
        fileprivate let began: Int
    }

    public enum Outcome: Equatable, Sendable {
        case publish, rerun, drop
    }

    private var clock = 0
    private var newestAllRead = 0
    private var newestItemRead: [String: Int] = [:]
    /// The freshness of the newest full list on screen (a rebuild on the main thread, or a full read published).
    private var newestFullList = 0
    /// The freshness of the newest change of any scope.
    private var newestChange = 0
    private var newestChangeToItem: [String: Int] = [:]
    /// The newest read of each scope whose caller has finished with it: it published, was dropped, or failed.
    private var newestEndedAllRead = 0
    private var newestEndedItemRead: [String: Int] = [:]
    /// The newest change whose item isn't known, so it may touch any item's rows.
    private var newestChangeToAnyItem = 0

    public init() {}

    /// A read of `scope` starts now.
    public mutating func beginRead(_ scope: Scope) -> Read {
        clock += 1
        switch scope {
        case .all: newestAllRead = clock
        case .item(let id): newestItemRead[id] = clock
        }
        return Read(scope: scope, began: clock)
    }

    /// The read landed. On `.publish` its rows count as written, so later-landing reads are judged against them.
    public mutating func finish(_ read: Read) -> Outcome {
        let began = read.began
        switch read.scope {
        case .all:
            if newestAllRead > began || newestFullList > began { return .drop }
            if newestChange > began { return .rerun }
            newestFullList = max(newestFullList, began)
        case .item(let id):
            if newestItemRead[id, default: 0] > began || newestFullList > began { return .drop }
            if newestChangeToItem[id, default: 0] > began || newestChangeToAnyItem > began { return .rerun }
            newestChangeToItem[id] = max(newestChangeToItem[id, default: 0], began)
        }
        newestChange = max(newestChange, began)
        return .publish
    }

    /// The caller is done with `read`: its rows are published, it was dropped, or it failed. A read that must read
    /// again isn't done until the last of its reads is.
    public mutating func end(_ read: Read) {
        switch read.scope {
        case .all: newestEndedAllRead = max(newestEndedAllRead, read.began)
        case .item(let id): newestEndedItemRead[id] = max(newestEndedItemRead[id, default: 0], read.began)
        }
    }

    /// A newer read of `read`'s scope has begun and none has ended yet. A dropped read whose caller is awaited waits
    /// for it, because the newer read holds everything the dropped one knew but may not have published it yet.
    public func isWaitingOnNewerRead(_ read: Read) -> Bool {
        switch read.scope {
        case .all: return newestAllRead > read.began && newestEndedAllRead <= read.began
        case .item(let id):
            return newestItemRead[id, default: 0] > read.began && newestEndedItemRead[id, default: 0] <= read.began
        }
    }

    /// Rows of `scope` changed on the main thread just now (a star, a note, an item's Margins removed).
    /// `.all` means the item isn't known, so every read in flight must read again.
    public mutating func noteChange(_ scope: Scope) {
        clock += 1
        switch scope {
        case .all: newestChangeToAnyItem = clock
        case .item(let id): newestChangeToItem[id] = clock
        }
        newestChange = clock
    }

    /// The whole list was rebuilt on the main thread just now, so every read in flight is older than it.
    public mutating func noteRebuild() {
        clock += 1
        newestFullList = clock
        newestChange = clock
    }
}
