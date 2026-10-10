import Foundation

/// Keeps the app running between one narration chunk ending and the next one playing (#540, #538).
///
/// Supertonic plays each chunk in its own player. When a chunk ends nothing is playing until the app, on its own
/// thread, makes the next player and starts it, so iOS has no audio keeping a backgrounded app alive for that
/// moment. The owner's phone logged the result twice: a ready item at time 0 with rate 0, and a watchdog that
/// only ran when he came back to the app. `NarrationStartupProtection` covers a start; this covers every seam
/// after it. Background time is held from the end of a chunk until the next one is heard moving, and it is
/// given back at once if the system takes it first.
@MainActor
public final class HandOverBackgroundHold {
    /// The same background-time call as a narration start: `UIApplication`'s in the app, a counter in tests.
    public typealias Begin = NarrationStartupProtection.Begin
    /// Records a playback event (kind and fields) in the app's diagnostics.
    public typealias Record = NarrationStartupProtection.Record

    public enum Outcome: String, Sendable {
        case held, unavailable, released, expired
    }

    /// A hand-over that took at least this long is worth a line in the playback events.
    public static let notableHold: TimeInterval = 2

    private let begin: Begin
    private let record: Record
    private let now: () -> Date
    private var release: (@MainActor () -> Void)?
    private var heldSince: Date?
    private var holdCount = 0

    public private(set) var outcome: Outcome?
    public var isHolding: Bool { release != nil }
    /// How many holds were asked for and granted.
    public var grantedCount: Int { holdCount }

    public init(begin: @escaping Begin, record: @escaping Record, now: @escaping () -> Date = Date.init) {
        self.begin = begin
        self.record = record
        self.now = now
    }

    /// A chunk finished and another follows. Holds until `nextChunkMoving()`; a second call while holding does nothing.
    public func chunkEnded() {
        guard release == nil else { return }
        let started = now()
        let hold = holdCount + 1
        let granted = begin("Narration chunk hand-over") { [weak self] in
            // A late expiry of an earlier hold must not end the current one.
            guard let self, self.holdCount == hold, self.release != nil else { return }
            self.finish(as: .expired)
        }
        guard let granted else {
            outcome = .unavailable
            record("handover.hold_unavailable", [:])
            return
        }
        holdCount = hold
        heldSince = started
        release = granted
        outcome = .held
    }

    /// The next chunk is playing, playback stopped or the iOS voice took over: nothing is left to hold for.
    public func nextChunkMoving() {
        finish(as: .released)
    }

    private func finish(as ending: Outcome) {
        guard let release else { return }
        self.release = nil
        outcome = ending
        let heldSeconds = heldSince.map { now().timeIntervalSince($0) } ?? 0
        heldSince = nil
        if ending == .expired || heldSeconds >= Self.notableHold {
            record(ending == .expired ? "handover.hold_expired" : "handover.hold_released", [
                "heldMs": String(max(0, Int((heldSeconds * 1_000).rounded())))
            ])
        }
        release()
    }
}
