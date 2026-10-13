import Foundation

/// Keeps a backgrounded app running while it waits for an audio interruption to end (#1434).
///
/// A message announced through AirPods interrupts narration. The app pauses and asks to resume when iOS says the
/// interruption ended. But once its audio stops, a backgrounded app can be suspended before that notice is sent, and
/// a suspended app never hears it. The owner's phone logged exactly that twice: `speech.interruption_began`, then
/// nothing, until a Play from the headset ten seconds later. The hold asks iOS for background time from the moment
/// the interruption begins until it ends or the listener takes over, so the "ended, resume" notice has an app to
/// reach. It gives the time back at once if the system takes it first.
///
/// Each hold also leaves one `speech.interruption_hold` event saying how the wait ended and how long it lasted,
/// so a device export shows whether iOS ever sent the end (outcome `ended`) or the app gave up waiting.
@MainActor
public final class InterruptionBackgroundHold {
    public typealias Begin = NarrationStartupProtection.Begin
    public typealias Record = NarrationStartupProtection.Record

    /// How the latest wait ended. `listener_acted`: Play, Pause or a new item before iOS reported the end.
    public enum Outcome: String, Sendable {
        case held, unavailable, ended, listenerActed = "listener_acted", expired
    }

    public static let eventKind = "speech.interruption_hold"

    private let begin: Begin
    private let record: Record
    private let now: () -> Date
    private var release: (@MainActor () -> Void)?
    private var heldSince: Date?
    private var holdCount = 0

    public private(set) var outcome: Outcome?
    public var isHolding: Bool { release != nil }

    public init(begin: @escaping Begin, record: @escaping Record, now: @escaping () -> Date = Date.init) {
        self.begin = begin
        self.record = record
        self.now = now
    }

    /// An interruption paused narration and asked to resume when it ends. A second call while holding does nothing.
    public func interruptionBegan() {
        guard release == nil else { return }
        let started = now()
        let hold = holdCount + 1
        let granted = begin("Audio interruption wait") { [weak self] in
            // A late expiry of an earlier hold must not end the current one.
            guard let self, self.holdCount == hold, self.release != nil else { return }
            self.finish(as: .expired)
        }
        guard let granted else {
            outcome = .unavailable
            record(Self.eventKind, ["outcome": Outcome.unavailable.rawValue])
            return
        }
        holdCount = hold
        heldSince = started
        release = granted
        outcome = .held
    }

    /// iOS reported the end of the interruption, with or without a request to resume.
    public func interruptionEnded() {
        finish(as: .ended)
    }

    /// The listener's own Play, Pause, Stop or a new item took over before iOS reported the end.
    public func listenerActed() {
        finish(as: .listenerActed)
    }

    private func finish(as ending: Outcome) {
        guard let release else { return }
        self.release = nil
        outcome = ending
        let heldSeconds = heldSince.map { now().timeIntervalSince($0) } ?? 0
        heldSince = nil
        record(Self.eventKind, [
            "outcome": ending.rawValue,
            "heldMs": String(max(0, Int((heldSeconds * 1_000).rounded())))
        ])
        release()
    }
}
