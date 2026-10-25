import Foundation

/// A spoken Margin recorded on the Apple Watch and sent to the phone (#2487). During a phone call the call holds the
/// iPhone's microphone, even when muted, but the Watch's microphone still records. The Watch sends the file with
/// `WCSession.transferFile` and this metadata; the phone files it into the live session it was spoken in.
public struct WatchMarginTransfer: Codable, Equatable, Sendable {
    /// The metadata keys. The Watch app's `WatchMarginTransferKeys` must use the same strings.
    public enum Key {
        public static let kind = "kind"
        public static let id = "id"
        /// Seconds since 1970, a Double.
        public static let wallStart = "wallStart"
        /// Seconds, a Double.
        public static let duration = "duration"
        public static let kindValue = "watchMargin"
    }

    public var id: String
    public var wallStart: Date
    public var durationMs: Int

    public init(id: String, wallStart: Date, durationMs: Int) {
        self.id = id
        self.wallStart = wallStart
        self.durationMs = durationMs
    }

    /// Reads the metadata the Watch sent. Nil when it isn't a Watch Margin or a field is missing.
    public init?(metadata: [String: Any]?) {
        guard let metadata,
              metadata[Key.kind] as? String == Key.kindValue,
              let id = (metadata[Key.id] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let start = (metadata[Key.wallStart] as? NSNumber)?.doubleValue, start.isFinite, start > 0 else { return nil }
        let seconds = (metadata[Key.duration] as? NSNumber)?.doubleValue ?? 0
        self.init(
            id: id,
            wallStart: Date(timeIntervalSince1970: start),
            durationMs: seconds.isFinite ? max(0, Int((seconds * 1_000).rounded())) : 0
        )
    }

    public var metadata: [String: Any] {
        [
            Key.kind: Key.kindValue,
            Key.id: id,
            Key.wallStart: wallStart.timeIntervalSince1970,
            Key.duration: Double(durationMs) / 1_000
        ]
    }

    /// The Margin's id in the live session. One transfer is one Margin, however often it arrives.
    public var marginId: String { "watch-\(id)" }

    /// Where the phone keeps the recording, named the way its Margin recorder names a spoken Margin.
    public var audioPath: String { "SpokenMargins/interjections/watch-\(Self.safeFileStem(id)).m4a" }

    static func safeFileStem(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let stem = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(stem.prefix(80))
    }
}

extension LiveSession {
    /// Adds a spoken Margin taken at `markedAt`, kept in time order. Returns false, changing nothing, when a Margin
    /// with this id is already there.
    @discardableResult
    public mutating func attachSpokenMargin(
        id: String, audioPath: String, markedAt: Date, durationMs: Int?, spokenOn: String, transcript: String = ""
    ) -> Bool {
        guard !margins.contains(where: { $0.id == id }) else { return false }
        var spoken = margin(id: id, text: transcript, markedAt: markedAt)
        spoken.audioPath = audioPath
        spoken.durationMs = durationMs
        spoken.spokenOn = spokenOn
        margins.append(spoken)
        margins.sort { $0.markedAt < $1.markedAt }
        return true
    }

    /// Files a Watch Margin into this session. False when it is already here.
    @discardableResult
    public mutating func attach(_ transfer: WatchMarginTransfer) -> Bool {
        attachSpokenMargin(
            id: transfer.marginId, audioPath: transfer.audioPath, markedAt: transfer.wallStart,
            durationMs: transfer.durationMs, spokenOn: "watch"
        )
    }

    /// Fills in a spoken Margin's transcript once it is ready, unless the listener has already written something.
    @discardableResult
    public mutating func setTranscript(_ text: String, forMarginId id: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = margins.firstIndex(where: { $0.id == id }),
              margins[index].isSpoken,
              margins[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        margins[index].text = trimmed
        return true
    }
}

/// The phone's answer to a Watch Margin (#2487 slice 1a; DESIGN section 4 point 3), sent after the recording is
/// stored and filed: filed, with the session's name and position; already filed; or rejected, with the reason in
/// plain words. It carries the inbox's `WatchMarginReceipt`, so the Watch can let go of exactly those bytes. The
/// Watch build before slice 1b ignores it.
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
    /// "Budget meeting", "a quick session", or the playing item's title when the phone knows it.
    public var filedIn: String?
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
}
