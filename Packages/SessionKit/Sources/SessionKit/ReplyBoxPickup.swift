import Foundation

/// One fetched answer, handed to the app's importer. `record` is the box's record as it stands now.
public struct ReplyBoxAnswer: Equatable, Sendable {
    public let record: ReplyBoxRecord
    /// The post's number in the box.
    public let seq: Int
    /// The `.spokenmargins` packet's exact bytes, as the friend's page wrote it.
    public let packet: Data
}

/// What the importer did with one answer.
public enum ReplyBoxImportOutcome: Equatable, Sendable {
    /// It is in the Library, on the shared item, as `layerId`. Imports are idempotent by digest (#468), so a packet
    /// fetched again comes back as the same layer with `newMarginCount` 0.
    case imported(ReplyBoxImported)
    /// Left out, with a Diagnostics reason. The cursor moves past it.
    case dropped(ReplyBoxAdmission.DropReason)
    /// Not now: the app is leaving the front or the store went away. The check stops and the cursor stays before this
    /// post, so the next check fetches it again.
    case notNow
}

public struct ReplyBoxImported: Equatable, Sendable {
    public let layerId: String
    /// The name the friend typed, as the packet carries it, or nil.
    public let senderLabel: String?
    /// The sender's own Library title for the shared item, never a title from the packet.
    public let itemTitle: String
    /// How many Margins this import added that the listener hasn't heard. 0 for a packet already in.
    public let newMarginCount: Int

    public init(layerId: String, senderLabel: String?, itemTitle: String, newMarginCount: Int) {
        self.layerId = layerId
        self.senderLabel = senderLabel
        self.itemTitle = itemTitle
        self.newMarginCount = newMarginCount
    }
}

/// The app's side of a pickup: it places each packet (quietly, with no screen change), decides whether it is an answer
/// to the shared item (``ReplyBoxAdmission`` holds the pure part of that rule), and says which layers are still in the
/// Library. Both are called off the main actor.
public protocol ReplyBoxImporting: Sendable {
    func importAnswer(_ answer: ReplyBoxAnswer) async -> ReplyBoxImportOutcome
    /// Whether the commentary layer is still in the Library, for the retention rule.
    func layerIsInLibrary(id: String) async -> Bool
}

/// One answer that arrived in a check: what banner C is built from (``ReplyArrivalWords/banner(for:)``).
public struct ReplyArrival: Equatable, Sendable {
    public let boxId: String
    public let seq: Int
    public let layerId: String
    public let itemId: String
    public let itemTitle: String
    public let senderLabel: String?
    public let newMarginCount: Int

    public init(
        boxId: String, seq: Int, layerId: String, itemId: String, itemTitle: String, senderLabel: String?,
        newMarginCount: Int
    ) {
        self.boxId = boxId
        self.seq = seq
        self.layerId = layerId
        self.itemId = itemId
        self.itemTitle = itemTitle
        self.senderLabel = senderLabel
        self.newMarginCount = newMarginCount
    }
}

public struct ReplyBoxCheckResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The check ran (it may have found nothing, or stopped partway: see `stoppedBy` and `interrupted`).
        case checked
        /// A check started less than two minutes ago.
        case throttled
        /// A check is running now.
        case alreadyRunning
        /// The store couldn't be opened. Nothing was read and no box was dropped.
        case storeUnavailable
    }

    public var status: Status
    /// New answers, in the order they were imported. Empty means show nothing.
    public var arrivals: [ReplyArrival] = []
    public var droppedCount = 0
    /// Posts that didn't open, passed over.
    public var skippedCount = 0
    /// Boxes the server said have ended (`410`) in this check.
    public var endedBoxIds: [String] = []
    /// Records deleted by the retention rule in this check.
    public var deletedBoxIds: [String] = []
    /// Set when the server couldn't be reached or was busy, which stops the check. Shows nothing.
    public var stoppedBy: ClubClient.Failure?
    /// The check stopped because the app left the front (the task was cancelled) or the importer said not now.
    public var interrupted = false

    public init(status: Status) {
        self.status = status
    }

    /// Banner C, or nil when nothing new arrived.
    public var banner: ReplyArrivalBanner? { ReplyArrivalWords.banner(for: arrivals) }
}

/// Collects answers from the sender's open reply boxes (#4675, `docs/design/reply-mailbox.md` piece 4). The app calls
/// ``check(_:)`` when it comes to the front and on Following's pull-to-refresh. It never runs in the background: the app
/// cancels the task when it leaves the front, and the check stops with every cursor where the last finished import
/// left it.
///
/// - At most every two minutes on coming to the front (an injected clock); pull-to-refresh always checks.
/// - Up to 20 boxes a check, those still readable (`now < expiresAt + 7 days`), the ones checked longest ago first.
/// - For each, the new posts are listed, then fetched one at a time, so at most one answer is in memory.
/// - Each opened packet goes to the importer; the cursor is saved only after it answers. A post that doesn't open is
///   passed over and the cursor moves. A `410` marks the box ended.
/// - Records past their read window are deleted once none of their answers' layers is in the Library.
public actor ReplyBoxPickup {
    public enum Trigger: Equatable, Sendable {
        case becameActive
        case pullToRefresh
    }

    public static let throttle: TimeInterval = 2 * 60
    public static let maximumBoxesPerCheck = 20

    private let client: ClubClient
    private let store: @Sendable () async throws -> any ReplyBoxStoring
    private let importer: any ReplyBoxImporting
    private let now: @Sendable () -> Date
    private let diagnostics: @Sendable (String) -> Void
    private var lastCheckStarted: Date?
    private var running = false

    /// `store` is awaited at the start of each check, so the app can hand it over only once its database is open; a
    /// check never reads an empty box list in the meantime. `diagnostics` gets one line per drop, with no content.
    public init(
        client: ClubClient,
        store: @escaping @Sendable () async throws -> any ReplyBoxStoring,
        importer: any ReplyBoxImporting,
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostics: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.client = client
        self.store = store
        self.importer = importer
        self.now = now
        self.diagnostics = diagnostics
    }

    public func check(_ trigger: Trigger = .becameActive) async -> ReplyBoxCheckResult {
        guard !running else { return ReplyBoxCheckResult(status: .alreadyRunning) }
        let started = now()
        if trigger == .becameActive, let last = lastCheckStarted, started.timeIntervalSince(last) < Self.throttle,
           started >= last {
            return ReplyBoxCheckResult(status: .throttled)
        }
        running = true
        let previousStart = lastCheckStarted
        lastCheckStarted = started
        defer { running = false }

        let store: any ReplyBoxStoring
        let records: [ReplyBoxRecord]
        do {
            store = try await self.store()
            records = try store.loadReplyBoxes()
        } catch {
            lastCheckStarted = previousStart
            return ReplyBoxCheckResult(status: .storeUnavailable)
        }
        var result = ReplyBoxCheckResult(status: .checked)
        await prune(records, in: store, at: started, into: &result)
        let due = records
            .filter { $0.isOpenForChecks(at: started) && !result.deletedBoxIds.contains($0.boxId) }
            .sorted { ($0.lastChecked ?? .distantPast, $0.boxId) < ($1.lastChecked ?? .distantPast, $1.boxId) }
            .prefix(Self.maximumBoxesPerCheck)

        boxes: for record in due {
            if Task.isCancelled { result.interrupted = true; break }
            guard let box = record.box else {
                // A damaged key can never open anything: end the box rather than ask about it on every check.
                diagnostics("reply_box.damaged_key")
                _ = try? store.updateReplyBox(id: record.boxId) { $0.ended = true; $0.lastChecked = started }
                continue
            }
            let numbers: [Int]
            do {
                numbers = try await client.listNew(for: box.invite, after: ClubClient.Cursor(lastPost: record.cursor))
            } catch {
                switch disposition(of: error) {
                case .stopCheck(let failure): result.stoppedBy = failure; break boxes
                case .interrupted: result.interrupted = true; break boxes
                case .ended:
                    markEnded(record.boxId, in: store, at: started, into: &result)
                    continue boxes
                case .nextBox:
                    _ = try? store.updateReplyBox(id: record.boxId) { $0.lastChecked = started }
                    continue boxes
                }
            }
            var current = record
            for number in numbers {
                if Task.isCancelled { result.interrupted = true; break boxes }
                let packet: Data?
                do {
                    packet = try await client.fetchPost(number, of: box.invite)
                } catch {
                    switch disposition(of: error) {
                    case .stopCheck(let failure): result.stoppedBy = failure; break boxes
                    case .interrupted: result.interrupted = true; break boxes
                    case .ended:
                        markEnded(record.boxId, in: store, at: started, into: &result)
                        continue boxes
                    case .nextBox: continue boxes
                    }
                }
                guard let packet else {
                    diagnostics(ReplyBoxAdmission.DropReason.unopenable.diagnosticsLine)
                    result.skippedCount += 1
                    guard let saved = save(number, answer: nil, for: current.boxId, in: store) else { continue boxes }
                    current = saved
                    continue
                }
                // Leaving the front between the fetch and the import: nothing is imported and the cursor stays.
                if Task.isCancelled { result.interrupted = true; break boxes }
                switch await importer.importAnswer(ReplyBoxAnswer(record: current, seq: number, packet: packet)) {
                case .notNow:
                    result.interrupted = true
                    break boxes
                case .dropped(let reason):
                    diagnostics(reason.diagnosticsLine)
                    result.droppedCount += 1
                    guard let saved = save(number, answer: nil, for: current.boxId, in: store) else { continue boxes }
                    current = saved
                case .imported(let imported):
                    guard let saved = save(
                        number, answer: .init(seq: number, layerId: imported.layerId), for: current.boxId, in: store
                    ) else { continue boxes }
                    current = saved
                    if imported.newMarginCount > 0 {
                        result.arrivals.append(ReplyArrival(
                            boxId: current.boxId, seq: number, layerId: imported.layerId, itemId: current.itemId,
                            itemTitle: imported.itemTitle, senderLabel: imported.senderLabel,
                            newMarginCount: imported.newMarginCount
                        ))
                    }
                }
            }
            _ = try? store.updateReplyBox(id: record.boxId) { $0.lastChecked = started }
        }
        return result
    }

    // MARK: Steps

    private enum Disposition {
        case stopCheck(ClubClient.Failure)
        case interrupted
        case ended
        case nextBox
    }

    private func disposition(of error: Error) -> Disposition {
        if error is CancellationError { return .interrupted }
        guard let failure = error as? ClubClient.Failure else { return .nextBox }
        switch failure {
        case .gone: return .ended
        case .offline, .serverProblem: return .stopCheck(failure)
        case .notFound, .clubFull, .tooLarge, .unexpected, .incompleteOrDamaged: return .nextBox
        }
    }

    /// Saves the cursor (and the answer) after the importer has answered. Nil when the record is gone or the store
    /// failed, which ends this box for this check with the cursor where it was.
    private func save(
        _ number: Int, answer: ReplyBoxRecord.Answer?, for boxId: String, in store: any ReplyBoxStoring
    ) -> ReplyBoxRecord? {
        try? store.updateReplyBox(id: boxId) { record in
            record.cursor = max(record.cursor, number)
            if let answer, !record.answers.contains(answer) { record.answers.append(answer) }
        }
    }

    private func markEnded(_ boxId: String, in store: any ReplyBoxStoring, at date: Date, into result: inout ReplyBoxCheckResult) {
        _ = try? store.updateReplyBox(id: boxId) { $0.ended = true; $0.lastChecked = date }
        result.endedBoxIds.append(boxId)
    }

    private func prune(
        _ records: [ReplyBoxRecord], in store: any ReplyBoxStoring, at date: Date, into result: inout ReplyBoxCheckResult
    ) async {
        for record in records where date >= record.readsUntil {
            var live = Set<String>()
            for answer in record.answers {
                if await importer.layerIsInLibrary(id: answer.layerId) { live.insert(answer.layerId) }
            }
            guard record.shouldDelete(at: date, layerIsInLibrary: live.contains) else { continue }
            if (try? store.deleteReplyBox(id: record.boxId)) != nil { result.deletedBoxIds.append(record.boxId) }
        }
    }
}
