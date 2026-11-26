import Foundation

/// The sender's two taps on an answer that came through a reply box (#4675, `docs/design/reply-mailbox.md` screens D and
/// E): stop answers through the link, and report the answer. Each sends one ``ReplyBoxRequests`` request through the
/// app's club transport and saves what it changed in the box's record. Hiding the answer is the app's (its
/// Hide-this-Margin store); ``ReplyBoxActions/ReportResult/hidesAnswer`` says when.
public struct ReplyBoxActions: Sendable {
    public enum StopResult: Equatable, Sendable {
        /// Stopped, or the box had already closed or ended: "Answers through this link are stopped."
        case stopped
        /// Offline, a server problem, or no such record: "Couldn't stop answers. Check your connection and try again."
        case failed
    }

    public enum ReportResult: Equatable, Sendable {
        /// The server filed it (`200`). `closeFailed` is true only when the listener asked to stop answers too and the
        /// close didn't go through; the report stands either way. `reasonOutstanding` keeps the sheet open for a
        /// written reason (a second report within 7 days).
        case filed(reference: String?, reasonOutstanding: Bool, closeFailed: Bool)
        /// `404`: the box ended more than 7 days ago, so nothing is left on the server.
        case boxEnded
        /// Offline, refused or no such record. Nothing is hidden or closed.
        case failed

        /// Whether the app hides the answer's Margins on this phone.
        public var hidesAnswer: Bool {
            switch self {
            case .filed, .boxEnded: true
            case .failed: false
            }
        }
    }

    /// The answers' small JSON bodies.
    static let maximumAnswerBytes = 4 << 10

    private let send: ClubClient.Send
    private let store: @Sendable () async throws -> any ReplyBoxStoring
    private let host: String
    private let now: @Sendable () -> Date

    /// `host` is the product host the transport sends to; an abuse-material report carries the box's link on it.
    public init(
        send: @escaping ClubClient.Send,
        store: @escaping @Sendable () async throws -> any ReplyBoxStoring,
        host: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.send = send
        self.store = store
        self.host = host
        self.now = now
    }

    /// The box and post an answer's layer came through, or nil when it came some other way. Only these layers show
    /// "Report this answer" and "Stop answers through this link" on their card.
    public static func answer(carrying layerId: String, in records: [ReplyBoxRecord]) -> (record: ReplyBoxRecord, seq: Int)? {
        for record in records {
            if let answer = record.answers.first(where: { $0.layerId == layerId }) { return (record, answer.seq) }
        }
        return nil
    }

    // MARK: Stop

    public func stop(boxId: String) async -> StopResult {
        guard let store = try? await store(), let record = Self.record(boxId, in: store) else { return .failed }
        return await close(record, in: store) ? .stopped : .failed
    }

    /// Sends the close and saves it as closed on success. A box the server no longer has counts as closed.
    private func close(_ record: ReplyBoxRecord, in store: any ReplyBoxStoring) async -> Bool {
        guard let request = try? ReplyBoxRequests.close(record),
              let response = try? await send(request, Self.maximumAnswerBytes),
              ReplyBoxRequests.closeOutcome(status: response.status) == .closed else { return false }
        let date = now()
        _ = try? store.updateReplyBox(id: record.boxId) { $0 = $0.markingClosed(at: date) }
        return true
    }

    // MARK: Report

    /// Reports post `seq` of the box. With `alsoStop`, a filed report then closes the box; a close that fails doesn't
    /// undo the report.
    public func report(
        boxId: String, seq: Int, category: ReplyReportCategory, reason: String?, alsoStop: Bool
    ) async -> ReportResult {
        guard let store = try? await store(), let record = Self.record(boxId, in: store),
              let request = try? ReplyBoxRequests.report(record, seq: seq, category: category, reason: reason, host: host),
              let response = try? await send(request, Self.maximumAnswerBytes) else { return .failed }
        switch ReplyBoxRequests.reportOutcome(status: response.status, body: response.body) {
        case .failed:
            return .failed
        case .boxEnded:
            let date = now()
            _ = try? store.updateReplyBox(id: boxId) { $0.ended = true; $0.lastChecked = date }
            return .boxEnded
        case .sent(let reference, let reasonOutstanding):
            var closeFailed = false
            if alsoStop, !record.closed {
                closeFailed = !(await close(record, in: store))
            }
            return .filed(reference: reference, reasonOutstanding: reasonOutstanding, closeFailed: closeFailed)
        }
    }

    /// Adds the written reason a second report owes. True when it went in.
    public func sendReason(boxId: String, reference: String, reason: String) async -> Bool {
        guard let store = try? await store(), let record = Self.record(boxId, in: store),
              let request = try? ReplyBoxRequests.reportReason(record, reference: reference, reason: reason),
              let response = try? await send(request, Self.maximumAnswerBytes) else { return false }
        return ReplyBoxRequests.reportReasonSucceeded(status: response.status)
    }

    private static func record(_ boxId: String, in store: any ReplyBoxStoring) -> ReplyBoxRecord? {
        (try? store.loadReplyBoxes())?.first { $0.boxId == boxId }
    }
}

/// The Report this answer sheet's state (screen E): what is chosen, what the footer says, and what happens when a send
/// comes back. The sheet draws from it; the rules are host-tested here.
public struct ReplyReportForm: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case editing
        case sending
        /// Filed, but the server asks for a written reason: the next send goes to `report/reason`.
        case reasonOwed(reference: String, closeFailed: Bool)
    }

    /// What the sheet does when it closes: the banner to show and whether to hide the answer.
    public struct Completion: Equatable, Sendable {
        public let banner: String
        public let hidesAnswer: Bool
    }

    public var category: ReplyReportCategory?
    public var reason = ""
    /// "Also stop answers through this link", on by default.
    public var alsoStop = true
    public private(set) var phase: Phase = .editing
    /// "Couldn't send the report…" after a failed send, cleared by the next one.
    public private(set) var failed = false

    public init() {}

    /// Send Report is enabled once a category is chosen and nothing is in flight. A reason owed needs some words.
    public var canSend: Bool {
        switch phase {
        case .editing: category != nil
        case .sending: false
        case .reasonOwed: !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var isSending: Bool { phase == .sending }

    /// The footer under the reason field, or nil.
    public var footer: String? {
        if failed { return ReplyArrivalWords.reportFailed }
        if case .reasonOwed = phase { return ReplyArrivalWords.reportReasonOutstanding }
        return nil
    }

    /// The reason to send, or nil when none was written.
    public var trimmedReason: String? {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Marks a send as started. Returns the phase it was sent from, so the caller knows which request to make.
    public mutating func beginSending() -> Phase? {
        guard canSend else { return nil }
        let from = phase
        phase = .sending
        failed = false
        return from
    }

    /// The report came back. Nil keeps the sheet open (a failure, or a reason owed); otherwise the sheet closes with
    /// the completion.
    public mutating func finishReport(_ result: ReplyBoxActions.ReportResult) -> Completion? {
        switch result {
        case .failed:
            phase = .editing
            failed = true
            return nil
        case .boxEnded:
            phase = .editing
            return Completion(banner: ReplyArrivalWords.reportBoxEnded, hidesAnswer: true)
        case .filed(let reference, let reasonOutstanding, let closeFailed):
            if reasonOutstanding, let reference {
                phase = .reasonOwed(reference: reference, closeFailed: closeFailed)
                return nil
            }
            phase = .editing
            return Completion(banner: ReplyArrivalWords.reportSent(reference: reference, closeFailed: closeFailed), hidesAnswer: true)
        }
    }

    /// The written reason came back. Nil keeps the sheet open with the failure footer.
    public mutating func finishReason(succeeded: Bool, reference: String, closeFailed: Bool) -> Completion? {
        guard succeeded else {
            phase = .reasonOwed(reference: reference, closeFailed: closeFailed)
            failed = true
            return nil
        }
        phase = .editing
        return Completion(banner: ReplyArrivalWords.reportSent(reference: reference, closeFailed: closeFailed), hidesAnswer: true)
    }

    /// Cancel. Once the report is filed (a reason owed), it stands: the sheet closes as if it were sent.
    public func cancelled() -> Completion? {
        guard case .reasonOwed(let reference, let closeFailed) = phase else { return nil }
        return Completion(banner: ReplyArrivalWords.reportSent(reference: reference, closeFailed: closeFailed), hidesAnswer: true)
    }
}
