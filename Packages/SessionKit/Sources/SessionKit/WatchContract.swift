import Foundation

// The Watch–phone contract (#2487 slice 1b; docs/design/live-sessions/DESIGN.md section 4, WATCH.md section 3).
//
// SessionKit compiles this file for the phone, and project.yml compiles it straight into the Watch app, which doesn't
// link SessionKit. So it uses Foundation only, and holds only the wire shapes: what goes between the devices and the
// words each side shows. The Watch's own state machines are in `WatchContractState.swift`, compiled the same way.
//
// Lanes (DESIGN section 4 point 4):
// - the sure lane: `transferUserInfo` for messages and answers, `transferFile` for audio. Every message goes here.
// - the fast lane: `sendMessage` with a reply, when the Watch app is in front and the phone is reachable. A speed-up
//   that wakes the phone app and measures the clock; never the only copy. It carries details, never audio.
// - the state board: application context, the phone's latest view of the session.

/// The contract's constants.
public enum WatchContract {
    /// Version 2 is slice 1b. The Watch build before it (version 1) sent only the file and read three context keys.
    public static let version = 2
    /// A `WatchEnvelope` travels as JSON data under this key, in `sendMessage` and `transferUserInfo` dictionaries.
    public static let envelopeKey = "smWatchEnvelope"
    /// A `WatchPhoneReply` travels as JSON data under this key in a fast-lane reply.
    public static let replyKey = "smPhoneReply"
    /// The `WatchBoard` travels as JSON data under this key in the application context.
    public static let boardKey = "smWatchBoard"
    /// No answer by then: the Watch says "Waiting for iPhone" (DESIGN default 14).
    public static let waitingAfter: TimeInterval = 15
    /// An unanswered Margin that WatchConnectivity no longer holds is sent again after this (DESIGN default 14).
    public static let retryAfter: TimeInterval = 10 * 60
    /// Resume undoes an End for this long (DESIGN section 2 point 6).
    public static let resumeWindow: TimeInterval = 10 * 60
    /// With the phone out of reach, a board older than this is shown "as of" its time (WATCH.md 2.3).
    public static let staleBoardAfter: TimeInterval = 60
    /// A clock measurement older than this isn't used (WATCH.md 3.5 point 4).
    public static let offsetMaxAge: TimeInterval = 24 * 60 * 60
    /// A round trip slower than this measures the clock too loosely to keep.
    public static let offsetMaxRoundTrip: TimeInterval = 10
    /// An offset larger than this is shown in the evidence (WATCH.md 3.5 point 5).
    public static let offsetWorthShowing: TimeInterval = 2
    /// Seconds as whole milliseconds that never trap: not-a-number and negative read as 0, and a huge value stops at
    /// `Int32.max` (about 24 days), because `Int` on the Watch can be 32 bits wide (#2964).
    public static func milliseconds(seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((min(seconds * 1_000, Double(Int32.max))).rounded())
    }
    /// A named session nobody ends closes itself this long after its start (DESIGN section 2 point 8).
    public static let autoEndAfter: TimeInterval = 8 * 60 * 60
}

/// A session's kind: the same four as the phone's `ElsewhereKind` (raw values match).
public enum WatchSessionKind: String, Codable, CaseIterable, Sendable {
    case meeting
    case audiobook
    case paper
    case other

    /// The name a session started on the Watch gets, and the kind button's label.
    public var label: String {
        switch self {
        case .meeting: "Meeting"
        case .audiobook: "Audiobook"
        case .paper: "Paper book"
        case .other: "Other"
        }
    }

    /// The placing hint shown while recording (DESIGN section 2 point 9, Watch short forms).
    public var hint: String {
        switch self {
        case .meeting: "Who, or what about? \u{201C}Johnny, on the budget\u{201D}"
        case .audiobook: "Where are you? \u{201C}chapter 5\u{201D}"
        case .paper: "Which page? \u{201C}page 118\u{201D}"
        case .other: "What was just said?"
        }
    }
}

/// The device that started a session, which decides its start and kind (WATCH.md 3.1).
public enum WatchDevice: String, Codable, Sendable {
    case phone
    case watch
}

/// The Watch's quick choices for "when did it end?" (#2709): the same as the phone's `LiveSessionEnd.quickChoices`, kept
/// here because the Watch target compiles only this file and `WatchContractState.swift`.
public enum WatchEndChoice: Equatable, Sendable {
    case now
    case minutesAgo(Int)

    /// A stopped time within this many seconds of the tap is "now": no second time is kept.
    public static let sameInstant: TimeInterval = 1

    public var label: String {
        switch self {
        case .now: "Now"
        case .minutesAgo(60): "1 hour ago"
        case let .minutesAgo(minutes): "\(minutes) minutes ago"
        }
    }

    public func date(tappedAt: Date) -> Date {
        switch self {
        case .now: tappedAt
        case let .minutesAgo(minutes): tappedAt.addingTimeInterval(-Double(max(0, minutes)) * 60)
        }
    }

    /// Now, 5, 15 and 30 minutes and an hour ago, leaving out any that fall before the session began.
    public static func choices(startedAt: Date, tappedAt: Date) -> [WatchEndChoice] {
        [.now, .minutesAgo(5), .minutesAgo(15), .minutesAgo(30), .minutesAgo(60)].filter { $0.date(tappedAt: tappedAt) >= startedAt }
    }
}

/// A session as the two devices describe it to each other: id, kind, title, owner device and start
/// (DESIGN section 9, changes point 11). Times are by the clock of the device that sent it.
public struct WatchSessionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var kind: WatchSessionKind
    public var title: String
    public var owner: WatchDevice
    public var startedAt: Date
    public var startPositionMs: Int?
    /// When the session ended as far as the Resume window is concerned: when the End was heard.
    public var endedAt: Date?
    /// When the listener said it stopped, when that was earlier than `endedAt` (#2709): "I stopped 15 minutes ago". Nil
    /// when they ended it at once. Optional, so a message from an earlier build still decodes.
    public var stoppedAt: Date?

    /// The end the listener sees: "Ended 14:05" is when it stopped, not when End was tapped.
    public var shownEnd: Date? { stoppedAt ?? endedAt }

    public init(
        id: String, kind: WatchSessionKind, title: String, owner: WatchDevice, startedAt: Date, startPositionMs: Int? = nil,
        endedAt: Date? = nil, stoppedAt: Date? = nil
    ) {
        self.stoppedAt = stoppedAt
        self.id = id
        self.kind = kind
        self.title = title
        self.owner = owner
        self.startedAt = startedAt
        self.startPositionMs = startPositionMs
        self.endedAt = endedAt
    }

    /// "Budget meeting", or the kind's name when it has no title.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.label : trimmed
    }
}

/// The phone's latest view, sent as the application context and in every fast-lane reply (WATCH.md 3.4 point 1).
/// Times are by the phone's clock.
public struct WatchBoard: Codable, Equatable, Sendable {
    /// The running named session, if any.
    public var running: WatchSessionInfo?
    /// The most recent named session that ended within `resumeWindow` and isn't saved yet, while nothing runs: the
    /// Watch offers Resume for it.
    public var recentlyEnded: WatchSessionInfo?
    /// Why the phone ended sessions the Watch started, by session id, in plain words: "Lecture ended at 10:20, when
    /// you started Meeting on iPhone". Kept for half a day.
    public var endNotes: [String: String]
    /// The phone's clock when it made this board.
    public var phoneTime: Date

    public init(running: WatchSessionInfo? = nil, recentlyEnded: WatchSessionInfo? = nil, endNotes: [String: String] = [:], phoneTime: Date) {
        self.running = running
        self.recentlyEnded = recentlyEnded
        self.endNotes = endNotes
        self.phoneTime = phoneTime
    }
}

/// The Watch's clock against the phone's, measured on a fast-lane round trip (WATCH.md 3.5).
public struct WatchClockStamp: Codable, Equatable, Sendable {
    /// The Watch's clock minus the phone's, in seconds. Positive when the Watch runs ahead.
    public var offset: TimeInterval
    /// When it was measured, by the Watch's clock.
    public var measuredAt: Date

    public init(offset: TimeInterval, measuredAt: Date) {
        self.offset = offset
        self.measuredAt = measuredAt
    }

    /// Measures it from one round trip: the Watch sent at `sentAt` and heard back at `receivedAt` (its clock), and
    /// the phone said `phoneTime` in between. Nil when the round trip was too slow, or went backwards, to trust.
    public static func measure(sentAt: Date, phoneTime: Date, receivedAt: Date) -> WatchClockStamp? {
        let roundTrip = receivedAt.timeIntervalSince(sentAt)
        guard roundTrip >= 0, roundTrip <= WatchContract.offsetMaxRoundTrip else { return nil }
        let midpoint = sentAt.addingTimeInterval(roundTrip / 2)
        return WatchClockStamp(offset: midpoint.timeIntervalSince(phoneTime), measuredAt: receivedAt)
    }

    /// Usable for a moment by the Watch's clock: measured within a day of it.
    public func isFresh(at time: Date) -> Bool {
        abs(time.timeIntervalSince(measuredAt)) <= WatchContract.offsetMaxAge
    }
}

/// A spoken Margin recorded on the Apple Watch (#2487). The Watch sends the audio with `WCSession.transferFile` and
/// this as its metadata, and the same details on the fast lane; the phone files it by `LiveSessionFiling`.
public struct WatchMarginTransfer: Codable, Equatable, Sendable {
    /// The metadata keys.
    public enum Key {
        public static let kind = "kind"
        public static let id = "id"
        /// Seconds since 1970, a Double.
        public static let wallStart = "wallStart"
        /// Seconds, a Double.
        public static let duration = "duration"
        public static let kindValue = "watchMargin"
        // Slice 1b. The Watch build before it sent none of these.
        public static let sessionId = "sessionId"
        /// Seconds, a Double: the Watch's clock minus the phone's.
        public static let clockOffset = "clockOffset"
        /// Seconds since 1970, a Double: when the offset was measured, by the Watch's clock.
        public static let clockMeasuredAt = "clockMeasuredAt"
        public static let sha256 = "sha256"
        public static let attempt = "attempt"
    }

    public var id: String
    /// When recording started, by the Watch's clock.
    public var wallStart: Date
    public var durationMs: Int
    /// The session the Watch says it was taken in. Nil with no session, so the phone files it by time.
    public var sessionId: String?
    /// The Watch's latest clock measurement when it was recorded.
    public var clock: WatchClockStamp?
    /// The Watch's checksum of the recording, lower-case hex. Empty when the sender didn't compute one.
    public var sha256: String
    /// 1 for the first send, rising with each retry.
    public var attempt: Int

    public init(id: String, wallStart: Date, durationMs: Int, sessionId: String? = nil, clock: WatchClockStamp? = nil, sha256: String = "", attempt: Int = 1) {
        self.id = id
        self.wallStart = wallStart
        self.durationMs = durationMs
        self.sessionId = sessionId
        self.clock = clock
        self.sha256 = sha256
        self.attempt = attempt
    }

    private enum CodingKeys: String, CodingKey {
        case id, wallStart, durationMs, sessionId, clock, sha256, attempt
    }

    /// Reads what slice 1a wrote beside a landed file too, which had only the first three fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            wallStart: try container.decode(Date.self, forKey: .wallStart),
            durationMs: try container.decode(Int.self, forKey: .durationMs),
            sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
            clock: try container.decodeIfPresent(WatchClockStamp.self, forKey: .clock),
            sha256: try container.decodeIfPresent(String.self, forKey: .sha256) ?? "",
            attempt: try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 1
        )
    }

    /// Reads the metadata the Watch sent. Nil when it isn't a Watch Margin or a field is missing.
    public init?(metadata: [String: Any]?) {
        guard let metadata,
              metadata[Key.kind] as? String == Key.kindValue,
              let id = (metadata[Key.id] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let start = (metadata[Key.wallStart] as? NSNumber)?.doubleValue, start.isFinite, start > 0 else { return nil }
        let seconds = (metadata[Key.duration] as? NSNumber)?.doubleValue ?? 0
        let sessionId = (metadata[Key.sessionId] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var clock: WatchClockStamp?
        if let offset = (metadata[Key.clockOffset] as? NSNumber)?.doubleValue, offset.isFinite,
           let measured = (metadata[Key.clockMeasuredAt] as? NSNumber)?.doubleValue, measured.isFinite, measured > 0 {
            clock = WatchClockStamp(offset: offset, measuredAt: Date(timeIntervalSince1970: measured))
        }
        self.init(
            id: id,
            wallStart: Date(timeIntervalSince1970: start),
            durationMs: WatchContract.milliseconds(seconds: seconds),
            sessionId: sessionId?.isEmpty == false ? sessionId : nil,
            clock: clock,
            sha256: (metadata[Key.sha256] as? String) ?? "",
            attempt: max(1, (metadata[Key.attempt] as? NSNumber)?.intValue ?? 1)
        )
    }

    /// Only property-list values, so WatchConnectivity accepts it.
    public var metadata: [String: Any] {
        var metadata: [String: Any] = [
            Key.kind: Key.kindValue,
            Key.id: id,
            Key.wallStart: wallStart.timeIntervalSince1970,
            Key.duration: Double(durationMs) / 1_000,
            Key.attempt: attempt
        ]
        if let sessionId { metadata[Key.sessionId] = sessionId }
        if let clock {
            metadata[Key.clockOffset] = clock.offset
            metadata[Key.clockMeasuredAt] = clock.measuredAt.timeIntervalSince1970
        }
        if !sha256.isEmpty { metadata[Key.sha256] = sha256 }
        return metadata
    }

    /// The Margin's id in the live session. One transfer is one Margin, however often it arrives.
    public var marginId: String { "watch-\(id)" }

    /// Where the phone keeps the recording, named the way its Margin recorder names a spoken Margin.
    public var audioPath: String { "SpokenMargins/interjections/watch-\(Self.safeFileStem(id)).m4a" }

    /// The id as the phone's inbox names it, and as its receipt answers it.
    public var captureId: String { Self.safeFileStem(id) }

    public static func safeFileStem(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(stem.prefix(80))
    }
}

/// Phone to Watch: what happened to a transferred Margin's bytes.
public struct WatchMarginReceipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        /// Stored durably on the phone for the first time.
        case stored
        /// Already stored; nothing new was imported.
        case duplicate
        /// The file's size didn't match: the transfer was cut short. Send it again.
        case incomplete
        /// The size matched but the bytes didn't. Send it again.
        case checksumMismatch
    }

    public var captureId: String
    public var sha256: String
    public var status: Status

    public init(captureId: String, sha256: String, status: Status) {
        self.captureId = captureId
        self.sha256 = sha256
        self.status = status
    }

    /// The phone holds these exact bytes, so the Watch may let them go.
    public var confirmsDelivery: Bool {
        status == .stored || status == .duplicate
    }
}

/// The phone's answer to a Watch Margin (DESIGN section 4 point 3), sent after the recording is stored and filed:
/// filed, with the session's name and position; already filed; or rejected, with the reason in plain words. It
/// carries the inbox's `WatchMarginReceipt`, so the Watch can let go of exactly those bytes.
public struct WatchMarginAnswer: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case filed
        case alreadyFiled
        case rejected
    }

    /// The `transferUserInfo` key the answer travels under, as JSON data.
    public static let userInfoKey = "watchMarginAnswer"

    public var receipt: WatchMarginReceipt
    public var outcome: Outcome
    public var sessionId: String?
    /// "Budget meeting", "a quick session", or "what was playing".
    public var filedIn: String?
    /// How far into the session it was taken.
    public var positionMs: Int?
    public var reason: String?

    public init(receipt: WatchMarginReceipt, outcome: Outcome, sessionId: String? = nil, filedIn: String? = nil, positionMs: Int? = nil, reason: String? = nil) {
        self.receipt = receipt
        self.outcome = outcome
        self.sessionId = sessionId
        self.filedIn = filedIn
        self.positionMs = positionMs
        self.reason = reason
    }

    /// The Watch may delete its copy only after this.
    public var confirmsFiled: Bool { receipt.confirmsDelivery && outcome != .rejected }

    /// "Filed in Budget meeting, about 1:10". Only ever built from the phone's answer.
    public var filedWords: String? {
        guard confirmsFiled else { return nil }
        let place = filedIn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var words = "Filed in \(place.isEmpty ? "your iPhone" : place)"
        if let positionMs, filedIn != "a quick session" { words += ", about \(WatchContractFormat.clock(ms: positionMs))" }
        return words
    }
}

/// A message from the Watch (WATCH.md 3.3).
public enum WatchMessage: Codable, Equatable, Sendable {
    /// Sent when the Watch app opens: the ids of every Margin it still holds. The phone answers with the board and
    /// an answer for each id it already filed.
    case hello(holding: [String])
    case sessionStart(WatchSessionInfo)
    /// The Watch ended a session, by its clock. When the phone owns the session this is a request to end it.
    /// `stoppedAt` is when the listener said it stopped, if earlier than `endedAt` (#2709).
    case sessionEnd(id: String, endedAt: Date, stoppedAt: Date? = nil)
    /// Resume within `resumeWindow` of an End: the same session runs again.
    case sessionResume(id: String)
    /// A Margin's details on the fast lane, ahead of its file.
    case marginDetails(WatchMarginTransfer)
    /// The listener deleted a waiting Margin on the Watch: a copy that arrives later is refused.
    case withdraw(id: String)
}

/// What travels: the message, the contract version, the Watch's clock at sending, and a counter that only rises.
public struct WatchEnvelope: Codable, Equatable, Sendable {
    public var v: Int
    public var seq: Int
    public var sentAt: Date
    public var clock: WatchClockStamp?
    public var message: WatchMessage

    public init(v: Int = WatchContract.version, seq: Int, sentAt: Date, clock: WatchClockStamp?, message: WatchMessage) {
        self.v = v
        self.seq = seq
        self.sentAt = sentAt
        self.clock = clock
        self.message = message
    }

    public var dictionary: [String: Any] {
        guard let data = try? WatchContractCoding.encoder.encode(self) else { return [:] }
        return [WatchContract.envelopeKey: data]
    }

    public init?(dictionary: [String: Any]) {
        guard let data = dictionary[WatchContract.envelopeKey] as? Data,
              let decoded = try? WatchContractCoding.decoder.decode(WatchEnvelope.self, from: data) else { return nil }
        self = decoded
    }
}

/// The phone's fast-lane reply: its clock, the board, and answers for Margins it already filed.
public struct WatchPhoneReply: Codable, Equatable, Sendable {
    public var phoneTime: Date
    public var board: WatchBoard
    public var answers: [WatchMarginAnswer]

    public init(phoneTime: Date, board: WatchBoard, answers: [WatchMarginAnswer] = []) {
        self.phoneTime = phoneTime
        self.board = board
        self.answers = answers
    }

    public var dictionary: [String: Any] {
        guard let data = try? WatchContractCoding.encoder.encode(self) else { return [:] }
        return [WatchContract.replyKey: data]
    }

    public init?(dictionary: [String: Any]) {
        guard let data = dictionary[WatchContract.replyKey] as? Data,
              let decoded = try? WatchContractCoding.decoder.decode(WatchPhoneReply.self, from: data) else { return nil }
        self = decoded
    }
}

extension WatchBoard {
    /// Reads the board from an application context.
    public init?(context: [String: Any]) {
        guard let data = context[WatchContract.boardKey] as? Data,
              let decoded = try? WatchContractCoding.decoder.decode(WatchBoard.self, from: data) else { return nil }
        self = decoded
    }

    public var encoded: Data? { try? WatchContractCoding.encoder.encode(self) }
}

extension WatchMarginAnswer {
    public var userInfo: [String: Any] {
        guard let data = try? WatchContractCoding.encoder.encode(self) else { return [:] }
        return [Self.userInfoKey: data]
    }

    public init?(userInfo: [String: Any]) {
        guard let data = userInfo[Self.userInfoKey] as? Data,
              let decoded = try? WatchContractCoding.decoder.decode(WatchMarginAnswer.self, from: data) else { return nil }
        self = decoded
    }
}

/// One JSON coding for the contract on both devices: dates as seconds since 1970, which keeps fractions.
public enum WatchContractCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Times as the Watch and the phone say them.
public enum WatchContractFormat {
    /// "1:10" or "1:02:03".
    public static func clock(ms: Int) -> String {
        let seconds = max(0, ms) / 1_000
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "14:05", in the device's time zone.
    public static func timeOfDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
