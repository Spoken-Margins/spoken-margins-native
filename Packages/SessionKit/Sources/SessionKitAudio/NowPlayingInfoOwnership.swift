import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Who is allowed to put a card on the system Now Playing surface (Lock Screen, Control Center).
public enum NowPlayingWriter: String, Sendable, Equatable {
    /// The podcast and publisher-audio player (`AVPlayerStreamPlaybackClient`), which also owns the transport commands.
    case mediaPlayer = "media_player"
    /// The compact-controls coordinator: live speech, and a metadata fallback for media when the player has not written.
    case compactControls = "compact_controls"
    /// A shared Margin's voice.
    case sharedMargin = "shared_margin"
}

/// One call to the ledger, for Diagnostics (#2181).
public struct NowPlayingLedgerEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case write
        /// A writer asked to fill the card only if nobody holds it, and someone did.
        case writeSkipped = "write_skipped"
        case clear
        /// A writer asked to clear a card another writer holds. The card stays.
        case clearIgnored = "clear_ignored"
        /// A marker with no change to the card, such as a move to the background.
        case note
    }

    public let kind: Kind
    public let writer: NowPlayingWriter?
    public let holderBefore: NowPlayingWriter?
    public let detail: String
    public let at: Date
}

/// The place the system card is written, so every clear says whose card it is clearing (#2181).
///
/// Three objects used to write `MPNowPlayingInfoCenter.nowPlayingInfo` directly, and several paths set it to nil without
/// checking who had written it. A clear meant for a finished live-speech card, or for a player that had stopped, then
/// removed the card another writer was keeping alive, and the Lock Screen lost its transport controls while the Live
/// Activity (which has none) stayed. Here a write makes its writer the holder, and a clear only takes effect from the holder.
public protocol NowPlayingInfoSink: AnyObject, Sendable {
    func setNowPlayingInfo(_ info: [String: Any]?)
    var hasNowPlayingInfo: Bool { get }
}

public final class SystemNowPlayingInfoSink: NowPlayingInfoSink, @unchecked Sendable {
    public init() {}

    public func setNowPlayingInfo(_ info: [String: Any]?) {
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    public var hasNowPlayingInfo: Bool {
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo != nil
        #else
        false
        #endif
    }
}

public final class NowPlayingInfoOwnership: @unchecked Sendable {
    public static let shared = NowPlayingInfoOwnership(sink: SystemNowPlayingInfoSink())

    /// Transitions kept for Diagnostics. Writes by the holder that already has the card are counted, not listed: the
    /// player writes every second and would push everything else out.
    private static let eventLimit = 12

    private let sink: NowPlayingInfoSink
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var holder: NowPlayingWriter?
    private var events: [NowPlayingLedgerEvent] = []
    private var repeatedWrites: [NowPlayingWriter: Int] = [:]

    public init(sink: NowPlayingInfoSink, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.now = now
    }

    /// The writer whose card is on the surface, or nil when nobody's is.
    public var currentHolder: NowPlayingWriter? {
        lock.lock()
        defer { lock.unlock() }
        return holder
    }

    /// Puts `info` on the surface and makes `writer` its holder.
    public func write(_ info: [String: Any], as writer: NowPlayingWriter, detail: String = "") {
        lock.lock()
        defer { lock.unlock() }
        let before = holder
        sink.setNowPlayingInfo(info)
        holder = writer
        if before == writer {
            repeatedWrites[writer, default: 0] += 1
        } else {
            record(.write, writer: writer, before: before, detail: detail)
        }
    }

    /// Puts `info` on the surface only when nobody holds a card. Returns whether it was written.
    @discardableResult
    public func writeIfUnheld(_ info: [String: Any], as writer: NowPlayingWriter, detail: String = "") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = holder
        guard before == nil || before == writer else {
            record(.writeSkipped, writer: writer, before: before, detail: detail)
            return false
        }
        sink.setNowPlayingInfo(info)
        holder = writer
        if before == writer {
            repeatedWrites[writer, default: 0] += 1
        } else {
            record(.write, writer: writer, before: before, detail: detail)
        }
        return true
    }

    /// Removes the card when `writer` holds it. Returns whether the card was removed. Another holder's card stays.
    @discardableResult
    public func clear(as writer: NowPlayingWriter, detail: String = "") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = holder
        guard before == writer else {
            // Nobody holds the card, or someone else does. Either way this writer has nothing of its own to remove.
            if before != nil { record(.clearIgnored, writer: writer, before: before, detail: detail) }
            return false
        }
        sink.setNowPlayingInfo(nil)
        holder = nil
        record(.clear, writer: writer, before: before, detail: detail)
        return true
    }

    /// Marks a moment in the history (a move to the background, say) with who holds the card and whether it is on the surface.
    public func note(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        record(.note, writer: nil, before: holder, detail: "\(label) card=\(sink.hasNowPlayingInfo ? "present" : "absent")")
    }

    /// One line for Diagnostics: the holder, the repeated-write counts, then the latest transitions, oldest first.
    public func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let counts = repeatedWrites
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)×\($0.value)" }
            .joined(separator: ",")
        let head = "holder=\(holder?.rawValue ?? "none") card=\(sink.hasNowPlayingInfo ? "present" : "absent") rewrites=\(counts.isEmpty ? "none" : counts)"
        guard !events.isEmpty else { return head }
        return ([head] + events.map(Self.describe)).joined(separator: " | ")
    }

    public func recentEvents() -> [NowPlayingLedgerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func record(_ kind: NowPlayingLedgerEvent.Kind, writer: NowPlayingWriter?, before: NowPlayingWriter?, detail: String) {
        // A refused call repeats on every player tick; the first one says it.
        if kind == .clearIgnored || kind == .writeSkipped,
           let last = events.last, last.kind == kind, last.writer == writer, last.holderBefore == before, last.detail == detail {
            return
        }
        events.append(NowPlayingLedgerEvent(kind: kind, writer: writer, holderBefore: before, detail: detail, at: now()))
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }

    private static func describe(_ event: NowPlayingLedgerEvent) -> String {
        let clock = ISO8601DateFormatter().string(from: event.at)
        let time = clock.count >= 19 ? String(clock.dropFirst(11).prefix(8)) : clock
        var parts = [time, event.kind.rawValue]
        if let writer = event.writer { parts.append(writer.rawValue) }
        parts.append("held=\(event.holderBefore?.rawValue ?? "none")")
        if !event.detail.isEmpty { parts.append(event.detail) }
        return parts.joined(separator: " ")
    }
}
