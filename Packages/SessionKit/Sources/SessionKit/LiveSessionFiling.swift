import Foundation

/// Where an incoming Margin goes (#2487 slice 1a; `docs/design/live-sessions/DESIGN.md` section 4 point 6, and
/// section 2 points 7 and 12). Pure: the phone's file worker gathers the sessions, deletions and player runs and
/// acts on the decision. In order:
///
/// 1. A Margin whose id is deleted is refused; one already filed in any session, ended and saved ones included,
///    is "already filed".
/// 2. The named session whose time span holds the Margin's time, after correcting for the recording device's
///    clock (the latest-started, if spans overlap).
/// 3. The session the Margin names: while it runs, or within 30 minutes after it ended ("after the session
///    ended"). A session the listener deleted refuses it.
/// 4. A session id the phone has never seen becomes a new session with that id (the Watch started it out of range).
/// 5. The item our own player was playing at that moment, at its position there.
/// 6. A quick session within 30 minutes of the Margin, else a new quick session.
///
/// A saved session (already a Library item) takes no new Margins: one that would have gone there makes a quick
/// session, so it is still seen. A Margin whose time falls only in a deleted session is refused, so a late copy
/// never brings a deleted meeting's Margins back.
public enum LiveSessionFiling {
    /// How long after an end a Margin that names the session still files into it.
    public static let afterEndWindow: TimeInterval = 30 * 60
    /// How close a Margin must be to a quick session's Margins to join it.
    public static let quickJoinWindow: TimeInterval = 30 * 60

    public static let afterEndNote = "after the session ended"
    public static let movedFromQuickNote = "moved from a quick session"

    /// A Margin to file.
    public struct Incoming: Equatable, Sendable {
        public var marginId: String
        /// When it was taken, by the recording device's clock.
        public var markedAt: Date
        /// The recording device's clock minus the phone's, when measured. Nil when unknown (today's Watch).
        public var clockOffset: TimeInterval?
        /// The session the recording device says it was taken in. Today's Watch and the Lock Screen name none.
        public var sessionId: String?
        /// False for a Margin that may not go onto the player's item.
        public var allowsPlayerItem: Bool

        public init(marginId: String, markedAt: Date, clockOffset: TimeInterval? = nil, sessionId: String? = nil, allowsPlayerItem: Bool = true) {
            self.marginId = marginId
            self.markedAt = markedAt
            self.clockOffset = clockOffset
            self.sessionId = sessionId
            self.allowsPlayerItem = allowsPlayerItem
        }

        /// Its time by the phone's clock.
        public var phoneTime: Date { markedAt.addingTimeInterval(-(clockOffset ?? 0)) }
    }

    /// What the rule needs to know of a stored session.
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var startedAt: Date
        /// Nil while it runs. A quick session's is its last Margin.
        public var endedAt: Date?
        public var isQuick: Bool
        public var isSaved: Bool
        public var marginIds: Set<String>

        public init(id: String, startedAt: Date, endedAt: Date?, isQuick: Bool = false, isSaved: Bool = false, marginIds: Set<String> = []) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isQuick = isQuick
            self.isSaved = isSaved
            self.marginIds = marginIds
        }

        public init(_ session: LiveSession) {
            self.init(
                id: session.id, startedAt: session.startedAt, endedAt: session.endedAt,
                isQuick: session.isQuick == true, isSaved: session.savedItemId != nil,
                marginIds: Set(session.margins.map(\.id))
            )
        }

        func holds(_ time: Date, now: Date) -> Bool {
            startedAt <= time && time <= (endedAt ?? max(now, time))
        }
    }

    /// What the listener deleted, kept so a late retry never brings it back.
    public struct Deletions: Codable, Equatable, Sendable {
        public struct Span: Codable, Equatable, Sendable {
            public var id: String
            public var startedAt: Date
            public var endedAt: Date?

            public init(id: String, startedAt: Date, endedAt: Date?) {
                self.id = id
                self.startedAt = startedAt
                self.endedAt = endedAt
            }
        }

        public var sessions: [Span]
        public var marginIds: Set<String>

        public init(sessions: [Span] = [], marginIds: Set<String> = []) {
            self.sessions = sessions
            self.marginIds = marginIds
        }

        public func deletedSession(_ id: String) -> Bool { sessions.contains { $0.id == id } }

        func deletedSessionHolds(_ time: Date) -> Bool {
            sessions.contains { $0.startedAt <= time && time <= ($0.endedAt ?? $0.startedAt) }
        }
    }

    /// A stretch when our own player was playing one item at a steady rate, from `startPositionMs`.
    public struct PlayerRun: Codable, Equatable, Sendable {
        public var itemId: String
        public var startedAt: Date
        public var endedAt: Date
        public var startPositionMs: Int
        public var rate: Double

        public init(itemId: String, startedAt: Date, endedAt: Date, startPositionMs: Int, rate: Double) {
            self.itemId = itemId
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.startPositionMs = startPositionMs
            self.rate = rate
        }

        public func positionMs(at time: Date) -> Int {
            max(0, startPositionMs + Int((time.timeIntervalSince(startedAt) * 1_000 * rate).rounded()))
        }
    }

    public enum Placement: String, Codable, Equatable, Sendable {
        case withinSpan
        case afterEnd
    }

    public enum RejectReason: String, Codable, Equatable, Sendable {
        case marginDeleted
        case sessionDeleted

        /// The reason in plain words, for the Watch and the phone's list.
        public var words: String {
            switch self {
            case .marginDeleted: "You deleted this Margin on your iPhone."
            case .sessionDeleted: "You deleted its session on your iPhone."
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        case alreadyFiled(sessionId: String)
        case rejected(RejectReason)
        case session(id: String, placement: Placement)
        case newNamedSession(id: String)
        case playerItem(itemId: String, positionMs: Int)
        case joinQuick(id: String)
        case newQuick
    }

    public static func decide(
        _ margin: Incoming, sessions: [Candidate], deletions: Deletions, playerRuns: [PlayerRun], now: Date
    ) -> Decision {
        if deletions.marginIds.contains(margin.marginId) { return .rejected(.marginDeleted) }
        if let holder = sessions.first(where: { $0.marginIds.contains(margin.marginId) }) { return .alreadyFiled(sessionId: holder.id) }
        let time = margin.phoneTime
        let open = sessions.filter { !$0.isSaved }

        // The named session whose span holds it.
        if let match = open.filter({ !$0.isQuick && $0.holds(time, now: now) }).max(by: { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }) {
            return .session(id: match.id, placement: .withinSpan)
        }

        // The session it names.
        if let named = margin.sessionId {
            if deletions.deletedSession(named) { return .rejected(.sessionDeleted) }
            if let session = sessions.first(where: { $0.id == named }) {
                if !session.isSaved {
                    if session.isQuick { return .joinQuick(id: session.id) }
                    guard let end = session.endedAt else { return .session(id: session.id, placement: .withinSpan) }
                    let after = time.timeIntervalSince(end)
                    if after > 0, after <= afterEndWindow { return .session(id: session.id, placement: .afterEnd) }
                }
            } else {
                return .newNamedSession(id: named)
            }
        }

        if deletions.deletedSessionHolds(time) { return .rejected(.sessionDeleted) }

        if margin.allowsPlayerItem, let run = playerRuns.last(where: { $0.startedAt <= time && time <= $0.endedAt }) {
            return .playerItem(itemId: run.itemId, positionMs: run.positionMs(at: time))
        }

        let nearby = open
            .filter(\.isQuick)
            .map { quick -> (Candidate, TimeInterval) in
                let end = quick.endedAt ?? quick.startedAt
                let gap = time < quick.startedAt ? quick.startedAt.timeIntervalSince(time) : max(0, time.timeIntervalSince(end))
                return (quick, gap)
            }
            .filter { $0.1 <= quickJoinWindow }
            .min { ($0.1, $1.0.startedAt) < ($1.1, $0.0.startedAt) }
        if let (quick, _) = nearby { return .joinQuick(id: quick.id) }
        return .newQuick
    }

    // MARK: Keeping quick sessions tidy (DESIGN section 2 point 7)

    /// A new quick session holding one Margin.
    public static func quickSession(id: String, holding margin: LiveSessionMargin) -> LiveSession {
        var session = LiveSession(
            id: id, kind: .other, title: "Quick session", startedAt: margin.markedAt, endedAt: margin.markedAt,
            margins: [], isQuick: true
        )
        session.add(margin)
        return session
    }

    /// Merges unsaved quick sessions whose spans overlap (the Watch and the phone each made one while apart), and
    /// moves quick Margins that an unsaved named session's span covers into it, noting "moved from a quick
    /// session". Returns the sessions to keep and the ids of quick sessions emptied and removed.
    public static func tidy(_ sessions: [LiveSession], now: Date) -> (sessions: [LiveSession], removedIds: [String]) {
        var named = sessions.filter { $0.isQuick != true || $0.savedItemId != nil }
        var quick = sessions.filter { $0.isQuick == true && $0.savedItemId == nil }.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        var removed: [String] = []

        // Covered by a named session.
        for index in quick.indices {
            for margin in quick[index].margins {
                guard let target = named.indices
                    .filter({ named[$0].savedItemId == nil && named[$0].isQuick != true && Candidate(named[$0]).holds(margin.markedAt, now: now) })
                    .max(by: { (named[$0].startedAt, named[$0].id) < (named[$1].startedAt, named[$1].id) }) else { continue }
                var moved = margin
                moved.filingNote = movedFromQuickNote
                named[target].add(moved)
                quick[index].margins.removeAll { $0.id == margin.id }
            }
        }
        quick = quick.filter { session in
            if session.margins.isEmpty { removed.append(session.id) }
            return !session.margins.isEmpty
        }
        for index in quick.indices { quick[index].fitQuickSpan() }

        // Overlapping quick sessions.
        var merged: [LiveSession] = []
        for session in quick {
            if let last = merged.indices.last, session.startedAt <= (merged[last].endedAt ?? merged[last].startedAt) {
                for margin in session.margins where !merged[last].margins.contains(where: { $0.id == margin.id }) {
                    merged[last].add(margin)
                }
                merged[last].fitQuickSpan()
                removed.append(session.id)
            } else {
                merged.append(session)
            }
        }
        return (named + merged, removed)
    }
}

extension LiveSession {
    /// Adds a Margin, keeping time order and each Margin's offset from the start. A quick session's span stretches
    /// to hold it.
    public mutating func add(_ margin: LiveSessionMargin) {
        guard !margins.contains(where: { $0.id == margin.id }) else { return }
        var added = margin
        added.sessionOffsetMs = max(0, Int((margin.markedAt.timeIntervalSince(startedAt) * 1_000).rounded()))
        margins.append(added)
        margins.sort { $0.markedAt < $1.markedAt }
        if isQuick == true { fitQuickSpan() }
    }

    /// A quick session runs from its first Margin to its last.
    mutating func fitQuickSpan() {
        guard isQuick == true, let first = margins.first?.markedAt, let last = margins.last?.markedAt else { return }
        startedAt = first
        endedAt = last
        for index in margins.indices {
            margins[index].sessionOffsetMs = max(0, Int((margins[index].markedAt.timeIntervalSince(startedAt) * 1_000).rounded()))
        }
    }
}
