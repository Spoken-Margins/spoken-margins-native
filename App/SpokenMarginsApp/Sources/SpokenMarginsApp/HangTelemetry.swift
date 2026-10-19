import Foundation
import SessionKit

/// What the app keeps, in everyday Diagnostics, to say where a freeze or a slow tap came from (#2099): a
/// probe that records `main.hang` when the main thread answers late, the last in-app tap, and the time a tap
/// or a close took to show. Only command names, status names, labels and millisecond counts; no titles, text or
/// ids. It costs one timer on a background queue and an empty block on the main queue per tick.
@MainActor
final class HangTelemetry {
    /// How often the probe pings the main queue while the app is in front, and while it is away (playback may
    /// go on there, so it keeps watching, but slowly).
    static let foregroundIntervalMs = 100
    static let backgroundIntervalMs = 1000

    /// The names of the work the main thread is in; the probe reads them while the thread is stuck.
    nonisolated let labels = MainThreadOperationLabels.shared

    /// Hangs written in one run. The always-on event log keeps 300 events, so a long run of stalls must not push
    /// the transport history out of it; past this, later hangs are not written (the last record says so with `lastOfRun`).
    static let maxHangRecordsPerRun = 50

    private var probe: MainThreadHangProbe?
    private var hangRecords = 0
    private var taps = TapToStateTracker()
    private var lastTapCommand = "none"
    private var lastTapAt: TimeInterval?
    private var closeTappedAt: TimeInterval?

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Starts the probe. `record` writes an event to Diagnostics; `context` gives the screen and playback status.
    func start(
        record: @escaping @MainActor (_ kind: String, _ fields: [String: String]) -> Void,
        context: @escaping @MainActor () -> [String: String]
    ) {
        guard probe == nil else { return }
        let probe = MainThreadHangProbe { [weak self] hang in
            // The probe watches the main queue, so this runs on the main thread, after the hang is over.
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.hangRecords < Self.maxHangRecordsPerRun else { return }
                self.hangRecords += 1
                var fields = context()
                if self.hangRecords == Self.maxHangRecordsPerRun { fields["lastOfRun"] = "true" }
                fields["durationMs"] = String(hang.durationMs)
                fields["operation"] = hang.operation.isEmpty ? "none" : hang.operation
                fields.merge(self.lastTapFields()) { current, _ in current }
                record("main.hang", fields)
            }
        }
        self.probe = probe
        probe.start(intervalMs: Self.foregroundIntervalMs)
    }

    func setForeground(_ foreground: Bool) {
        probe?.start(intervalMs: foreground ? Self.foregroundIntervalMs : Self.backgroundIntervalMs)
    }

    // MARK: Taps

    /// An in-app transport tap, with the playback status it saw.
    func noteTap(command: String, status: String) {
        let now = Self.now()
        taps.tapped(command: command, status: status, at: now)
        lastTapCommand = command
        lastTapAt = now
    }

    /// The `transport.state` fields when `status` is the first change after a tap; nil otherwise.
    func statusChanged(to status: String) -> [String: String]? {
        taps.statusChanged(to: status, at: Self.now())
    }

    /// The last tap's command and how long ago it was, when that was within a minute.
    func lastTapFields() -> [String: String] {
        guard let at = lastTapAt else { return ["lastTap": "none"] }
        let agoMs = Int(((Self.now() - at) * 1000).rounded())
        return agoMs <= 60_000 ? ["lastTap": lastTapCommand, "lastTapAgoMs": String(agoMs)] : ["lastTap": "none"]
    }

    // MARK: Closing the mini player

    func closeTapped() { closeTappedAt = Self.now() }

    /// Milliseconds since the accepted close tap, once; nil if no close waits.
    func takeCloseElapsedMs() -> Int? {
        guard let at = closeTappedAt else { return nil }
        closeTappedAt = nil
        return Int(((Self.now() - at) * 1000).rounded())
    }
}
