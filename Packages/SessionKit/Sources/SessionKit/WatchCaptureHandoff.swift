import Foundation

/// The item the phone is playing, as both devices name it (#788).
///
/// `revision` changes whenever the item's playable content changes (a re-import, a new edition),
/// so a position read against one revision is never applied to another.
public struct WatchCaptureSource: Codable, Equatable, Hashable, Sendable {
    public var itemId: String
    public var revision: String

    public init(itemId: String, revision: String) {
        self.itemId = itemId
        self.revision = revision
    }
}

/// What the phone's own player says right now. The app builds it from its existing playback
/// snapshot when a Watch message arrives; nothing here reads or drives a player.
public struct PhonePlaybackReading: Equatable, Sendable {
    public var source: WatchCaptureSource?
    public var positionMs: Int?
    public var isPlaying: Bool
    /// Counts explicit transport commands from any surface: play, pause, seek, skip, item change.
    /// The pause this handoff asks for must not count, or every capture would look overridden.
    public var transportGeneration: Int
    public var readAt: Date

    public init(source: WatchCaptureSource?, positionMs: Int?, isPlaying: Bool, transportGeneration: Int, readAt: Date) {
        self.source = source
        self.positionMs = positionMs
        self.isPlaying = isPlaying
        self.transportGeneration = transportGeneration
        self.readAt = readAt
    }
}

/// Watch to phone: the listener started a Margin on the Watch.
public struct WatchCaptureRequest: Codable, Equatable, Sendable {
    /// Made on the Watch, stable for the capture's whole life, and the key everything else uses.
    public var captureId: String
    /// What the Watch last saw playing, from the phone's snapshot, if it saw anything.
    public var observedSource: WatchCaptureSource?
    /// The phone's transport generation in that snapshot.
    public var observedTransportGeneration: Int?
    public var requestedAt: Date

    public init(captureId: String, observedSource: WatchCaptureSource?, observedTransportGeneration: Int?, requestedAt: Date) {
        self.captureId = captureId
        self.observedSource = observedSource
        self.observedTransportGeneration = observedTransportGeneration
        self.requestedAt = requestedAt
    }
}

/// Where a Watch Margin belongs, read from the phone's player.
public struct WatchCaptureAnchor: Codable, Equatable, Sendable {
    public enum Precision: String, Codable, Equatable, Sendable {
        /// The phone's position when the request arrived, with nothing in between to move it.
        case exact
        /// The phone's position, but something moved playback between the press and the reading.
        case approximate
    }

    public enum ApproximateReason: String, Codable, Equatable, Sendable {
        /// A play, pause, seek or skip happened after the Watch's snapshot and before the request.
        case transportChangedDuringRequest
        /// Playback ran on for longer than `WatchCaptureHandoff.lateRequestTolerance` before the
        /// request arrived, so the reading is later than the press.
        case requestArrivedLate
    }

    public var source: WatchCaptureSource
    public var positionMs: Int
    public var precision: Precision
    public var approximateReason: ApproximateReason?

    public init(source: WatchCaptureSource, positionMs: Int, precision: Precision, approximateReason: ApproximateReason? = nil) {
        self.source = source
        self.positionMs = positionMs
        self.precision = precision
        self.approximateReason = approximateReason
    }
}

/// Why a Watch Margin has no anchor. The Margin is still kept; it is placed by the listener later.
public enum WatchCaptureAnchorUnavailableReason: String, Codable, Equatable, Sendable {
    /// The phone had no item loaded.
    case nothingLoaded
    /// The phone had an item but no position for it.
    case noPosition
    /// The phone's reading was older than `WatchCaptureHandoff.readingTolerance`.
    case staleReading
    /// The phone is playing a different item or revision from the one the Watch showed.
    case sourceChanged
    /// The Watch finished the Margin before the phone heard it start; playback ran on meanwhile.
    case requestArrivedAfterFinish
}

public enum WatchCaptureAnchorOutcome: Codable, Equatable, Sendable {
    case anchored(WatchCaptureAnchor)
    case unavailable(WatchCaptureAnchorUnavailableReason)

    public var anchor: WatchCaptureAnchor? {
        if case .anchored(let anchor) = self { return anchor }
        return nil
    }
}

/// Phone to Watch: the answer to a `WatchCaptureRequest`.
public struct WatchCaptureAcknowledgement: Codable, Equatable, Sendable {
    public var captureId: String
    public var anchor: WatchCaptureAnchorOutcome
    /// The phone paused playback for this capture.
    public var pausedPlayback: Bool

    public init(captureId: String, anchor: WatchCaptureAnchorOutcome, pausedPlayback: Bool) {
        self.captureId = captureId
        self.anchor = anchor
        self.pausedPlayback = pausedPlayback
    }
}

/// How a Watch capture ended.
public enum WatchCaptureEnd: String, Codable, Equatable, Sendable {
    case saved
    case cancelled
    case failed
}

/// The phone side of a Margin recorded on the Watch while the phone plays (#788, slice of #96).
///
/// The phone owns playback; the Watch owns the microphone. When the Watch starts a Margin the
/// phone pauses, reads the anchor from its own player and acknowledges; when the Watch ends it the
/// phone resumes, unless a newer play, pause or seek has happened since. Commands can arrive twice
/// or out of order (WatchConnectivity retries and queues), so every answer is keyed by capture id.
///
/// It returns decisions and owns nothing: the app carries them out with its existing pause and
/// resume, and resume always continues from the player's own position.
public struct WatchCaptureHandoff: Sendable {
    /// A reading older than this when the request is handled gives no anchor.
    public static let readingTolerance: TimeInterval = 2
    /// Playback that ran on longer than this between the press and the reading makes the anchor
    /// approximate.
    public static let lateRequestTolerance: TimeInterval = 1.5
    /// Finished capture ids kept to answer duplicates and late starts.
    public static let finishedMemory = 64
    /// A capture whose end never arrives (the Watch died mid-Margin) stops holding playback
    /// paused for other captures after this long.
    public static let openCaptureTimeout: TimeInterval = 10 * 60

    public enum BeginDecision: Equatable, Sendable {
        /// New capture. Pause playback first when `pausedPlayback` is true, then send the
        /// acknowledgement.
        case start(WatchCaptureAcknowledgement)
        /// The same request again: resend the acknowledgement and change nothing.
        case duplicate(WatchCaptureAcknowledgement)
        /// The Watch already ended this capture: send the acknowledgement (no anchor) and leave
        /// playback alone.
        case alreadyEnded(WatchCaptureAcknowledgement)
    }

    public enum FinishDecision: Equatable, Sendable {
        /// Resume the phone's player from its own position.
        case resumePlayback
        case leavePlayback(LeaveReason)
        case ignored(IgnoreReason)
    }

    public enum LeaveReason: Equatable, Sendable {
        /// Playback wasn't paused by a Watch capture.
        case notPausedForCapture
        /// Someone played, paused, sought or skipped since the capture paused playback.
        case newerTransportCommand
        /// Another Watch capture is still recording.
        case anotherCaptureOpen
    }

    public enum IgnoreReason: Equatable, Sendable {
        /// The end arrived before the start. It is remembered, so the late start won't pause.
        case endBeforeStart
        case alreadyEnded
    }

    private struct Record: Sendable {
        var acknowledgement: WatchCaptureAcknowledgement
        var beganAt: Date
        var end: WatchCaptureEnd?
    }

    private var records: [String: Record] = [:]
    /// Ended ids, oldest first, so memory stays bounded.
    private var endedOrder: [String] = []
    /// Ends that arrived before their start, oldest first.
    private var earlyEnds: [(captureId: String, end: WatchCaptureEnd)] = []
    /// The transport generation when a Watch capture paused playback; nil when it didn't.
    public private(set) var pausedAtTransportGeneration: Int?

    public init() {}

    /// Capture ids still recording, as of `now`.
    public func openCaptureIds(now: Date) -> [String] {
        records.filter { $0.value.end == nil && now.timeIntervalSince($0.value.beganAt) <= Self.openCaptureTimeout }
            .map(\.key)
            .sorted()
    }

    public mutating func begin(_ request: WatchCaptureRequest, reading: PhonePlaybackReading, now: Date) -> BeginDecision {
        if let record = records[request.captureId] {
            return .duplicate(record.acknowledgement)
        }
        if let index = earlyEnds.firstIndex(where: { $0.captureId == request.captureId }) {
            let end = earlyEnds.remove(at: index).end
            let acknowledgement = WatchCaptureAcknowledgement(
                captureId: request.captureId,
                anchor: .unavailable(.requestArrivedAfterFinish),
                pausedPlayback: false
            )
            remember(request.captureId, Record(acknowledgement: acknowledgement, beganAt: now, end: end))
            return .alreadyEnded(acknowledgement)
        }

        let anchor = Self.anchor(for: request, reading: reading, now: now)
        let pauses = reading.isPlaying
        if pauses {
            pausedAtTransportGeneration = reading.transportGeneration
        }
        let acknowledgement = WatchCaptureAcknowledgement(captureId: request.captureId, anchor: anchor, pausedPlayback: pauses)
        records[request.captureId] = Record(acknowledgement: acknowledgement, beganAt: now, end: nil)
        return .start(acknowledgement)
    }

    /// The Watch ended a capture. `reading` is the phone's player now; its `readAt` is the clock.
    public mutating func end(captureId: String, as end: WatchCaptureEnd, reading: PhonePlaybackReading) -> FinishDecision {
        guard var record = records[captureId] else {
            if !earlyEnds.contains(where: { $0.captureId == captureId }) {
                earlyEnds.append((captureId, end))
                if earlyEnds.count > Self.finishedMemory { earlyEnds.removeFirst() }
            }
            return .ignored(.endBeforeStart)
        }
        guard record.end == nil else { return .ignored(.alreadyEnded) }
        record.end = end
        remember(captureId, record)

        // Saved, cancelled and failed all hand playback back the same way.
        guard openCaptureIds(now: reading.readAt).isEmpty else { return .leavePlayback(.anotherCaptureOpen) }
        guard let pausedAt = pausedAtTransportGeneration else { return .leavePlayback(.notPausedForCapture) }
        pausedAtTransportGeneration = nil
        guard reading.transportGeneration == pausedAt else { return .leavePlayback(.newerTransportCommand) }
        return .resumePlayback
    }

    private mutating func remember(_ captureId: String, _ record: Record) {
        records[captureId] = record
        endedOrder.removeAll { $0 == captureId }
        endedOrder.append(captureId)
        while endedOrder.count > Self.finishedMemory {
            records.removeValue(forKey: endedOrder.removeFirst())
        }
    }

    static func anchor(for request: WatchCaptureRequest, reading: PhonePlaybackReading, now: Date) -> WatchCaptureAnchorOutcome {
        guard let source = reading.source else { return .unavailable(.nothingLoaded) }
        guard let positionMs = reading.positionMs else { return .unavailable(.noPosition) }
        guard now.timeIntervalSince(reading.readAt) <= Self.readingTolerance else { return .unavailable(.staleReading) }
        if let observed = request.observedSource, observed != source {
            return .unavailable(.sourceChanged)
        }
        if let observedGeneration = request.observedTransportGeneration, observedGeneration != reading.transportGeneration {
            return .anchored(WatchCaptureAnchor(source: source, positionMs: positionMs, precision: .approximate, approximateReason: .transportChangedDuringRequest))
        }
        if reading.isPlaying, reading.readAt.timeIntervalSince(request.requestedAt) > Self.lateRequestTolerance {
            return .anchored(WatchCaptureAnchor(source: source, positionMs: positionMs, precision: .approximate, approximateReason: .requestArrivedLate))
        }
        return .anchored(WatchCaptureAnchor(source: source, positionMs: positionMs, precision: .exact))
    }
}
