import Foundation
import SessionKit

/// Runs the list checker for a trigger (#4046 PR 6). It is the only caller of `ListLinkChecker`, and it answers
/// `FollowedRefreshTrigger.checksListLinks` before it touches the store or the network, so the launch refresh, the
/// background refresh, a follow and an undo never read a list address.
///
/// One pass at a time. A request that arrives while a pass runs is not dropped and does not start a second pass beside it:
/// when the pass ends each distinct request made meanwhile is served in turn, so a pull to refresh during an
/// open-Following check still reads every link, and two requests at once make one proposal, not two (the second pass
/// finds the file unchanged, or the same change, and writes the same proposal).
public actor ListLinkRunner {
    public struct Report: Equatable, Sendable {
        /// The links read this run (not skipped as not due), in the order they were read.
        public var checkedLinkIDs: [String] = []
        /// The store failed to answer or to save.
        public var storeFailed = false
    }

    public enum Outcome: Equatable, Sendable {
        /// The trigger is not one that reads list addresses. Nothing was touched.
        case notChecked
        /// A pass is running; this request will be served when it ends.
        case queued
        case finished(Report)
    }

    private struct Request: Equatable {
        var trigger: FollowedRefreshTrigger
        var onlyLinkID: String?
    }

    private let store: any ListLinkStoring
    private let checker: ListLinkChecker
    private let clock: @Sendable () -> Date
    private var isRunning = false
    private var waiting: [Request] = []

    public init(store: any ListLinkStoring, checker: ListLinkChecker, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.checker = checker
        self.clock = clock
    }

    /// Starts a run and returns at once. A pull's spinner must not wait on a slow list host, and the caller (on the main actor)
    /// should not need a `Task` of its own to say so.
    public nonisolated func runWithoutWaiting(trigger: FollowedRefreshTrigger) {
        guard trigger.checksListLinks else { return }
        Task { await self.run(trigger: trigger) }
    }

    /// - Parameter onlyLinkID: **Check now** on one list reads that link and no other.
    @discardableResult
    public func run(trigger: FollowedRefreshTrigger, onlyLinkID: String? = nil) async -> Outcome {
        guard trigger.checksListLinks else { return .notChecked }
        let request = Request(trigger: trigger, onlyLinkID: onlyLinkID)
        guard !isRunning else {
            if !waiting.contains(request) { waiting.append(request) }
            return .queued
        }
        isRunning = true
        defer { isRunning = false }
        var report = Report()
        var queue = [request]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let pass = await pass(current)
            report.checkedLinkIDs += pass.checkedLinkIDs
            report.storeFailed = report.storeFailed || pass.storeFailed
            // Requests made during the pass. Ones the pass already serves are dropped.
            // A cancelled pass keeps what was queued: those callers were told `.queued`.
            if Task.isCancelled { break }
            let arrived = waiting
            waiting = []
            for more in arrived where !queue.contains(more) && !Self.covers(current, more) { queue.append(more) }
        }
        return .finished(report)
    }

    /// Whether the pass for `done` serves a `later` request made while it ran: it read every link `later` asks for (or more),
    /// at least as strongly, moments before. A request that forces more than `done` did is not covered.
    private static func covers(_ done: Request, _ later: Request) -> Bool {
        guard done.trigger.forcesListLinkCheck || !later.trigger.forcesListLinkCheck else { return false }
        return done.onlyLinkID == nil || done.onlyLinkID == later.onlyLinkID
    }

    private func pass(_ request: Request) async -> Report {
        var report = Report()
        let links: [ListLink]
        let existing: Set<String>
        do {
            links = try await store.listLinks()
            existing = try await store.existingListIDs()
        } catch {
            report.storeFailed = true
            return report
        }
        let now = clock()
        let due = links.filter {
            existing.contains($0.listId)
                && (request.onlyLinkID == nil || $0.id == request.onlyLinkID)
                && ListLinkSchedule.isDue($0, trigger: request.trigger, now: now)
        }
        for link in due {
            guard !Task.isCancelled, let checked = await checker.check(link, now: clock()) else { break }
            report.checkedLinkIDs.append(link.id)
            do { try await store.saveChecked(checked) } catch { report.storeFailed = true }
        }
        return report
    }
}
