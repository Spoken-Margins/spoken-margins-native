import Foundation

/// Keeps the app running in the background while on-device narration is starting (#854).
///
/// Narration rendered on the phone plays through the app's own player. While a start is pending nothing is playing
/// yet, so iOS has no audio keeping a backgrounded app alive and can suspend it before the first word. Only a fresh
/// start used to be protected. Resuming after a Margin, cancelling one, play from pause and the Lock Screen or Live
/// Activity all went back to "starting" without protection, so leaving the app right then left narration silent
/// until the listener came back. Every status change is fed here instead, so each of those starts is protected the
/// same way: background time is held from the first "starting" until the status leaves it.
///
/// It also records what the phone's diagnostics lacked: when the app went to the background and came back, and how
/// a start that ended in the background went (how long it took and whether it reached "playing").
@MainActor
public final class NarrationStartupProtection {
    /// Asks the system for background time. Returns the call that gives it back, or nil when the system refused.
    /// `expired` is called if the system takes the time back first.
    public typealias Begin = @MainActor (_ name: String, _ expired: @escaping @MainActor () -> Void)
        -> (@MainActor () -> Void)?
    /// Records a playback event (kind and fields) in the app's diagnostics.
    public typealias Record = @MainActor (_ kind: String, _ fields: [String: String]) -> Void

    /// What happened to the latest protection, for the app's diagnostics.
    public enum Outcome: String, Sendable {
        case protected, unavailable, completed, expired
    }

    private struct Start {
        var startedAt: Date
        var backgrounded: Bool
    }

    private let begin: Begin
    private let record: Record
    private let outcomeChanged: @MainActor (Outcome) -> Void
    private let now: () -> Date
    private var release: (@MainActor () -> Void)?
    private var protectionCount = 0
    private var start: Start?
    private var status: PlaybackStatus = .idle
    private var itemId: String?

    public private(set) var outcome: Outcome? {
        didSet { if let outcome, outcome != oldValue { outcomeChanged(outcome) } }
    }
    public private(set) var isInBackground = false
    public var isProtecting: Bool { release != nil }

    /// `outcomeChanged` reports each new outcome, including an expiry, for the app's diagnostics.
    public init(
        begin: @escaping Begin, record: @escaping Record,
        outcomeChanged: @escaping @MainActor (Outcome) -> Void = { _ in }, now: @escaping () -> Date = Date.init
    ) {
        self.begin = begin
        self.record = record
        self.outcomeChanged = outcomeChanged
        self.now = now
    }

    /// Protects a start that is about to be requested, before the engine publishes "starting". A fresh start does
    /// its first work (loading the item, the first render) before it reaches "starting", and that work needs
    /// protecting too. A status change other than "starting" releases it.
    public func protectUpcomingStart(eligible: Bool) {
        guard eligible else { return }
        protect()
    }

    /// Feed every status change. Entering "starting" protects the start when `eligible` says the narration is
    /// rendered on the device, and so does a start that moves to another item while starting (a podcast start
    /// replaced by an article's); any other status releases the protection.
    public func statusChanged(to newStatus: PlaybackStatus, itemId newItemId: String? = nil, eligible: () -> Bool) {
        let previous = status
        let previousItemId = itemId
        status = newStatus
        itemId = newItemId
        if newStatus == .starting {
            if previous != .starting {
                start = Start(startedAt: now(), backgrounded: isInBackground)
            }
            if (previous != .starting || newItemId != previousItemId), !isProtecting, eligible() { protect() }
            return
        }
        if let start {
            self.start = nil
            if isInBackground {
                record("startup.background_end", [
                    "durationMs": String(Self.milliseconds(from: start.startedAt, to: now())),
                    "reachedPlaying": String(newStatus == .playing),
                    "status": newStatus.rawValue,
                    "startedInBackground": String(start.backgrounded),
                    "outcome": outcome?.rawValue ?? "none",
                ])
            }
        }
        end(as: .completed)
    }

    public func appEnteredBackground() {
        guard !isInBackground else { return }
        isInBackground = true
        record("app.background", eventFields())
    }

    public func appEnteredForeground() {
        guard isInBackground else { return }
        isInBackground = false
        record("app.foreground", eventFields())
    }

    /// Releases any protection, for app termination.
    public func stop() {
        end(as: .completed)
    }

    private func protect() {
        guard release == nil else { return }
        protectionCount += 1
        let protection = protectionCount
        release = begin("Start native text audio") { [weak self] in
            // A late expiry of an earlier protection must not end the current one.
            guard let self, self.protectionCount == protection else { return }
            self.end(as: .expired)
        }
        outcome = release == nil ? .unavailable : .protected
    }

    private func end(as ending: Outcome) {
        guard let release else { return }
        self.release = nil
        outcome = ending
        release()
    }

    private func eventFields() -> [String: String] {
        var fields = ["status": status.rawValue, "protected": String(isProtecting)]
        if let start { fields["startingMs"] = String(Self.milliseconds(from: start.startedAt, to: now())) }
        return fields
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}
