import Foundation

/// What the app keeps, in everyday Diagnostics, to say where a freeze or a slow tap came from (#2099): a
/// probe that records `main.hang` when the main thread answers late, the last in-app tap, and the time a tap
/// or a close took to show. Only command names, status names, labels and millisecond counts; no titles, text or
/// ids. It costs one timer on a background queue and an empty block on the main queue per tick.
@MainActor
public final class HangTelemetry {
    /// How often the probe pings the main queue while the app is in front, and while it is away (playback may
    /// go on there, so it keeps watching, but slowly).
    public static let foregroundIntervalMs = 100
    public static let backgroundIntervalMs = 1000

    /// The names of the work the main thread is in; the probe reads them while the thread is stuck.
    public nonisolated let labels = MainThreadOperationLabels.shared

    /// At most this many hangs are written in any `hangWindowSeconds`. The always-on event log keeps 300 events,
    /// so a long run of stalls must not push the transport history out of it. Hangs left out are counted in the
    /// next record's `skipped` field.
    public static let maxHangRecordsPerWindow = 20
    public static let hangWindowSeconds: TimeInterval = 600

    /// Told of every hang the probe reports, including the ones the event log's allowance leaves out. The launch
    /// history keeps the stalls of a launch's first minute this way (#3752).
    public var hangObserver: (@MainActor (MainThreadHangProbe.Hang) -> Void)?

    private var probe: MainThreadHangProbe?
    private var hangRecords = 0
    private var hangWindowStart: TimeInterval = 0
    private var hangsSkipped = 0
    private var taps = TapToStateTracker()
    private var lastTapCommand = "none"
    private var lastTapAt: TimeInterval?
    private var closeTappedAt: TimeInterval?

    /// Seconds of uptime; a test passes its own clock.
    private let clock: @Sendable () -> TimeInterval

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    private func uptime() -> TimeInterval { clock() }

    /// Starts the probe. `record` writes an event to Diagnostics; `context` gives the screen and playback status.
    public func start(
        record: @escaping @MainActor (_ kind: String, _ fields: [String: String]) -> Void,
        context: @escaping @MainActor () -> [String: String]
    ) {
        guard probe == nil else { return }
        let newProbe = MainThreadHangProbe { [weak self] hang in
            // The probe watches the main queue, so this runs on the main thread, after the hang is over.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handle(hang, record: record, context: context)
            }
        }
        probe = newProbe
        newProbe.start(intervalMs: Self.foregroundIntervalMs)
    }

    /// Writes one `main.hang` record for `hang`, unless this window's allowance is spent; a hang left out is
    /// counted in the next record's `skipped` field.
    func handle(
        _ hang: MainThreadHangProbe.Hang,
        record: @MainActor (_ kind: String, _ fields: [String: String]) -> Void,
        context: @MainActor () -> [String: String]
    ) {
        hangObserver?(hang)
        let now = uptime()
        if now - hangWindowStart > Self.hangWindowSeconds {
            hangWindowStart = now
            hangRecords = 0
        }
        guard hangRecords < Self.maxHangRecordsPerWindow else {
            hangsSkipped += 1
            return
        }
        hangRecords += 1
        var fields = context()
        if hangsSkipped > 0 {
            fields["skipped"] = String(hangsSkipped)
            hangsSkipped = 0
        }
        fields["durationMs"] = String(hang.durationMs)
        fields["operation"] = hang.operation.isEmpty ? "none" : hang.operation
        if !hang.samples.isEmpty { fields["operationSamples"] = hang.samplesField }
        fields.merge(lastTapFields()) { current, _ in current }
        record("main.hang", fields)
    }

    public func setForeground(_ foreground: Bool) {
        probe?.start(intervalMs: foreground ? Self.foregroundIntervalMs : Self.backgroundIntervalMs)
    }

    // MARK: Taps

    /// An in-app transport tap, with the playback status it saw.
    public func noteTap(command: String, status: String) {
        let now = uptime()
        taps.tapped(command: command, status: status, at: now)
        lastTapCommand = command
        lastTapAt = now
    }

    /// The `transport.state` fields when `status` is the first change after a tap; nil otherwise.
    public func statusChanged(to status: String) -> [String: String]? {
        taps.statusChanged(to: status, at: uptime())
    }

    /// The last tap's command and how long ago it was, when that was within a minute.
    public func lastTapFields() -> [String: String] {
        guard let at = lastTapAt else { return ["lastTap": "none"] }
        let agoMs = Int(((uptime() - at) * 1000).rounded())
        return agoMs <= 60_000 ? ["lastTap": lastTapCommand, "lastTapAgoMs": String(agoMs)] : ["lastTap": "none"]
    }

    // MARK: Closing the mini player

    public func closeTapped() { closeTappedAt = uptime() }

    /// Milliseconds since the accepted close tap, once; nil if no close waits.
    public func takeCloseElapsedMs() -> Int? {
        guard let at = closeTappedAt else { return nil }
        closeTappedAt = nil
        return Int(((uptime() - at) * 1000).rounded())
    }
}
