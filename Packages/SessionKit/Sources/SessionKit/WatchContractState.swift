import Foundation

// The Watch's two state machines (#2487 slice 1b), pure so they are host-tested in SessionKit and compiled straight
// into the Watch app (Foundation only, like WatchContract.swift). The Watch app wraps them with WatchConnectivity,
// the recorder and a file on disk; every decision is made here.

/// What the Watch holds until the phone says "filed" (DESIGN section 4 points 2 and 3; WATCH.md 2.6 and 3.6).
///
/// - A recording stays until an answer for its exact id confirms the phone holds the same bytes and filed them.
/// - An unanswered Margin is sent again after `retryAfter` once WatchConnectivity no longer holds it, and at once
///   after a "hello" that didn't answer it. A failed transfer goes back to "saved" and is sent again.
/// - Answers can be lost, repeated, or arrive out of order: "filed" is final, a later rejection of the same id never
///   undoes it, and an answer for a Margin the Watch no longer holds (filed, or deleted here) changes nothing.
/// - A rejection whose bytes arrived (the listener deleted it on the iPhone) waits with Retry and Delete. A damaged
///   transfer is sent again on its own.
public struct WatchMarginLedger: Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        /// Closed and safe on the Watch; not handed to WatchConnectivity yet, or the last try failed.
        case saved
        /// Handed to WatchConnectivity at this time (the Watch's clock), with no answer yet.
        case sent(at: Date)
        /// The phone answered that it can't file it, in plain words. Waits for Retry or Delete.
        case rejected(reason: String)
    }

    public struct Held: Codable, Equatable, Sendable, Identifiable {
        public var transfer: WatchMarginTransfer
        /// The recording's file name in the Watch's recordings folder.
        public var fileName: String
        public var status: Status
        /// When it was saved, by the Watch's clock.
        public var savedAt: Date
        public var lastError: String?

        public var id: String { transfer.id }
    }

    /// A Margin the phone filed: kept, without audio, so the Watch can say where it went.
    public struct Filed: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var words: String
        public var sessionId: String?
        public var filedAt: Date
    }

    /// What the Watch shows for one Margin, in words and an icon shape (never colour alone).
    public enum Display: Equatable, Sendable {
        case savedOnWatch
        case waitingForIPhone
        case filed(String)
        case couldNotFile(String)

        public var words: String {
            switch self {
            case .savedOnWatch: "Saved on Watch"
            case .waitingForIPhone: "Waiting for iPhone"
            case .filed(let words): words
            case .couldNotFile(let reason): "Not filed: \(reason)"
            }
        }

        /// An SF Symbol whose shape carries the state.
        public var symbol: String {
            switch self {
            case .savedOnWatch: "applewatch"
            case .waitingForIPhone: "hourglass"
            case .filed: "checkmark.circle"
            case .couldNotFile: "exclamationmark.triangle"
            }
        }
    }

    /// What applying an answer did, for the app to act on.
    public enum Effect: Equatable, Sendable {
        /// Nothing held by that id: already filed, deleted here, or never recorded on this Watch.
        case ignored
        /// The phone filed it: delete this recording file.
        case filed(fileName: String)
        /// The transfer was damaged: it is sent again on the next turn.
        case willResend
        /// The phone refused it: it waits with Retry and Delete.
        case rejected
    }

    public private(set) var held: [Held] = []
    public private(set) var filed: [Filed] = []
    /// Ids the listener deleted here, so a late answer or a hello never brings one back. The newest 500.
    public private(set) var deleted: [String] = []
    /// How many recent filed records to keep for display.
    public static let filedKept = 20

    public init() {}

    public func held(_ id: String) -> Held? { held.first { $0.id == id } }

    /// The ids the Watch still holds, for "hello".
    public var holdingIds: [String] { held.map(\.id) }

    /// Margins not yet filed: the "1 waiting" count on Home.
    public var waitingCount: Int { held.count }

    // MARK: Recording and sending

    /// A finished recording, closed and on the Watch's disk.
    public mutating func record(_ transfer: WatchMarginTransfer, fileName: String, now: Date) {
        guard held(transfer.id) == nil, !deleted.contains(transfer.id), !filed.contains(where: { $0.id == transfer.id }) else { return }
        held.append(Held(transfer: transfer, fileName: fileName, status: .saved, savedAt: now))
    }

    /// The ids to hand to WatchConnectivity now, oldest first: never sent, failed, or sent `retryAfter` ago with no
    /// answer and no longer in WatchConnectivity's own queue (`inFlight`). A rejected Margin waits for Retry.
    public func due(now: Date, inFlight: Set<String>) -> [String] {
        held.compactMap { item in
            switch item.status {
            case .saved:
                return inFlight.contains(item.id) ? nil : item.id
            case .sent(let at):
                guard !inFlight.contains(item.id), now.timeIntervalSince(at) >= WatchContract.retryAfter else { return nil }
                return item.id
            case .rejected:
                return nil
            }
        }
    }

    /// Marks it handed to WatchConnectivity, and returns what to send, its attempt counted.
    public mutating func markSent(_ id: String, now: Date) -> WatchMarginTransfer? {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return nil }
        if case .rejected = held[index].status { return nil }
        held[index].transfer.attempt = sentBefore(held[index]) ? held[index].transfer.attempt + 1 : held[index].transfer.attempt
        held[index].status = .sent(at: now)
        held[index].lastError = nil
        return held[index].transfer
    }

    private func sentBefore(_ item: Held) -> Bool {
        if case .saved = item.status, item.lastError == nil { return false }
        return true
    }

    /// WatchConnectivity gave up on a transfer: it goes back to "saved" and is sent again on the next turn.
    public mutating func transferFailed(_ id: String, error: String) {
        guard let index = held.firstIndex(where: { $0.id == id }), case .sent = held[index].status else { return }
        held[index].status = .saved
        held[index].lastError = error
    }

    /// After a "hello" whose reply didn't answer these ids, they are due at once unless WatchConnectivity still holds
    /// them (WATCH.md 3.6 point 3).
    public mutating func unansweredAfterHello(answered: Set<String>, inFlight: Set<String>) {
        for index in held.indices where !answered.contains(held[index].id) && !inFlight.contains(held[index].id) {
            if case .sent = held[index].status {
                held[index].status = .saved
                held[index].lastError = "not answered after hello"
            }
        }
    }

    // MARK: The phone's answers

    /// Applies one answer. Safe to repeat, and safe in any order.
    public mutating func apply(_ answer: WatchMarginAnswer, now: Date) -> Effect {
        let id = answer.receipt.captureId
        guard let index = held.firstIndex(where: { WatchMarginTransfer.safeFileStem($0.id) == id }) else { return .ignored }
        let item = held[index]
        if answer.confirmsFiled {
            // The phone must hold these exact bytes. An empty checksum is a Margin filed before the phone kept one.
            let sameBytes = answer.receipt.sha256.isEmpty || item.transfer.sha256.isEmpty || answer.receipt.sha256 == item.transfer.sha256
            guard sameBytes else {
                held[index].status = .rejected(reason: "Your iPhone has a different copy of this Margin.")
                return .rejected
            }
            held.remove(at: index)
            filed.append(Filed(id: item.id, words: answer.filedWords ?? "Filed", sessionId: answer.sessionId, filedAt: now))
            filed = Array(filed.suffix(Self.filedKept))
            return .filed(fileName: item.fileName)
        }
        if !answer.receipt.confirmsDelivery {
            held[index].status = .saved
            held[index].lastError = "phone_\(answer.receipt.status.rawValue)"
            return .willResend
        }
        held[index].status = .rejected(reason: answer.reason ?? "Your iPhone couldn't file it.")
        return .rejected
    }

    // MARK: The listener's Retry and Delete

    /// Retry: sent again on the next turn.
    public mutating func retry(_ id: String) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        held[index].status = .saved
        held[index].lastError = "retried by the listener"
    }

    /// Delete: the Watch lets go of it. Returns the recording's file name to remove.
    public mutating func delete(_ id: String) -> String? {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return nil }
        let item = held.remove(at: index)
        deleted.append(item.id)
        deleted = Array(deleted.suffix(500))
        return item.fileName
    }

    // MARK: Showing it

    public func display(_ id: String, now: Date) -> Display? {
        if let item = held(id) {
            switch item.status {
            case .rejected(let reason):
                return .couldNotFile(reason)
            case .saved, .sent:
                return now.timeIntervalSince(item.savedAt) >= WatchContract.waitingAfter ? .waitingForIPhone : .savedOnWatch
            }
        }
        if let done = filed.last(where: { $0.id == id }) { return .filed(done.words) }
        return nil
    }
}

/// The session as the Watch knows it (DESIGN section 3; WATCH.md 2.2, 2.4, 2.13): the phone's board, a session
/// started here that the phone hasn't confirmed, and Ends made here. It picks Home's state line.
public struct WatchSessionModel: Codable, Equatable, Sendable {
    /// The phone's latest board, and when it arrived by the Watch's clock.
    public private(set) var board: WatchBoard?
    public private(set) var boardReceivedAt: Date?
    /// A session started on this Watch that the board doesn't show yet. Times by the Watch's clock.
    public private(set) var local: WatchSessionInfo?
    /// Sessions ended here, by id, with their end by the Watch's clock, until the board stops showing them running.
    public private(set) var endedHere: [String: Date] = [:]
    /// The last session ended here or by the phone, for Resume and the "ended" line. Times by the Watch's clock.
    public private(set) var lastEnded: WatchSessionInfo?
    /// "Lecture ended at 10:20, when you started Meeting on iPhone", when the phone ended a session the Watch started.
    public private(set) var endNote: String?
    /// The latest clock measurement.
    public var clock: WatchClockStamp?

    public init() {}

    /// Home's state.
    public struct Home: Equatable, Sendable {
        public enum Place: Equatable, Sendable {
            case none
            case onPhone
            case onWatch
        }

        public var place: Place
        public var session: WatchSessionInfo?
        /// "as of 14:05" when the phone can't be reached and the board is old.
        public var asOf: Date?
        /// A session ended within the resume window, while nothing runs.
        public var resumable: WatchSessionInfo?
        public var endNote: String?

        /// "No session", "Budget meeting · on iPhone · about 12:40", "Lecture · on Watch · 14:02".
        public func line(now: Date) -> String {
            guard let session else { return "No session" }
            var parts = [session.displayTitle, place == .onWatch ? "on Watch" : "on iPhone"]
            if let start = session.startPositionMs {
                parts.append("about \(WatchContractFormat.clock(ms: start + Int(max(0, now.timeIntervalSince(session.startedAt)) * 1_000)))")
            } else {
                parts.append(WatchContractFormat.timeOfDay(session.startedAt))
            }
            if let asOf { parts.append("as of \(WatchContractFormat.timeOfDay(asOf))") }
            return parts.joined(separator: " · ")
        }

        /// An SF Symbol whose shape carries the state: an empty circle, a phone, a watch.
        public var symbol: String {
            switch place {
            case .none: "circle"
            case .onPhone: "iphone"
            case .onWatch: "applewatch"
            }
        }
    }

    /// The board's time on the Watch's clock.
    private func watchTime(_ phoneTime: Date) -> Date {
        guard let clock else { return phoneTime }
        return phoneTime.addingTimeInterval(clock.offset)
    }

    private func onWatchClock(_ info: WatchSessionInfo) -> WatchSessionInfo {
        var converted = info
        converted.startedAt = watchTime(info.startedAt)
        converted.endedAt = info.endedAt.map(watchTime)
        return converted
    }

    private static func endsItself(_ info: WatchSessionInfo, now: Date) -> Bool {
        now.timeIntervalSince(info.startedAt) >= WatchContract.autoEndAfter
    }

    /// The running session, by the Watch's clock, and where it runs.
    public func running(now: Date) -> (WatchSessionInfo, Home.Place)? {
        if let local, endedHere[local.id] == nil, !Self.endsItself(local, now: now) { return (local, .onWatch) }
        if let running = board?.running, endedHere[running.id] == nil {
            let converted = onWatchClock(running)
            if !Self.endsItself(converted, now: now) { return (converted, running.owner == .watch ? .onWatch : .onPhone) }
        }
        return nil
    }

    public func home(now: Date, phoneReachable: Bool) -> Home {
        if let (session, place) = running(now: now) {
            var asOf: Date?
            if place == .onPhone, !phoneReachable, let received = boardReceivedAt,
               now.timeIntervalSince(received) > WatchContract.staleBoardAfter {
                asOf = received
            }
            return Home(place: place, session: session, asOf: asOf, resumable: nil, endNote: nil)
        }
        return Home(place: .none, session: nil, asOf: nil, resumable: resumable(now: now), endNote: endNote)
    }

    /// The session Resume would reopen, while nothing runs.
    public func resumable(now: Date) -> WatchSessionInfo? {
        var candidates: [WatchSessionInfo] = []
        if let lastEnded { candidates.append(lastEnded) }
        if let ended = board?.recentlyEnded { candidates.append(onWatchClock(ended)) }
        return candidates
            .filter { info in
                guard let end = info.endedAt else { return false }
                let since = now.timeIntervalSince(end)
                return since >= 0 && since <= WatchContract.resumeWindow
            }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
    }

    /// The session a Margin recorded now belongs to. Nil with none, so the phone files it by time (a quick session).
    public func sessionIdForMargin(now: Date) -> String? {
        running(now: now)?.0.id
    }

    // MARK: Changes made here

    /// Start session, then a kind: running at once (WATCH.md 2.4). The later start ends any earlier one.
    public mutating func start(kind: WatchSessionKind, id: String, now: Date) -> WatchSessionInfo {
        if let (previous, _) = running(now: now) { endedHere[previous.id] = now }
        let info = WatchSessionInfo(id: id, kind: kind, title: kind.label, owner: .watch, startedAt: now)
        local = info
        endNote = nil
        lastEnded = nil
        return info
    }

    /// End: whichever session runs, on either device. Returns its id and end, to send.
    public mutating func end(now: Date) -> (id: String, endedAt: Date)? {
        guard let (session, _) = running(now: now) else { return nil }
        endedHere[session.id] = now
        var ended = session
        ended.endedAt = now
        lastEnded = ended
        if local?.id == session.id { local = nil }
        endNote = nil
        return (session.id, now)
    }

    /// Resume, within ten minutes of an End: the same session runs again. Returns its id, to send.
    public mutating func resume(now: Date) -> String? {
        guard running(now: now) == nil, var session = resumable(now: now) else { return nil }
        endedHere[session.id] = nil
        session.endedAt = nil
        if session.owner == .watch { local = session }
        lastEnded = nil
        endNote = nil
        return session.id
    }

    // MARK: The phone's board

    public mutating func apply(_ newBoard: WatchBoard, receivedAt: Date) {
        board = newBoard
        boardReceivedAt = receivedAt
        let running = newBoard.running

        // Ends made here are done once the phone no longer shows that session running.
        for id in endedHere.keys where running?.id != id { endedHere[id] = nil }
        // A resumed session the phone shows running again is no longer "last ended".
        if let lastEnded, running?.id == lastEnded.id, endedHere[lastEnded.id] == nil { self.lastEnded = nil }

        guard let mine = local else { return }
        if running?.id == mine.id {
            local = nil // the phone has it
            return
        }
        if let note = newBoard.endNotes[mine.id] {
            endPhoneSide(mine, note: note, at: newBoard.recentlyEnded?.id == mine.id ? newBoard.recentlyEnded?.endedAt.map(watchTime) : nil)
            return
        }
        if let other = running, watchTime(other.startedAt) >= mine.startedAt {
            // The phone started one after this one: the later start ends the earlier (DESIGN default 1).
            let at = watchTime(other.startedAt)
            endPhoneSide(mine, note: "\(mine.displayTitle) ended at \(WatchContractFormat.timeOfDay(at)), when you started \(other.displayTitle) on iPhone", at: at)
        }
        // Otherwise the phone hasn't heard of it yet: it stays "on Watch".
    }

    private mutating func endPhoneSide(_ session: WatchSessionInfo, note: String, at: Date?) {
        var ended = session
        ended.endedAt = at ?? boardReceivedAt
        lastEnded = ended
        local = nil
        endNote = note
    }
}
