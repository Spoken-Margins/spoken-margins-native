import Foundation
import SessionKit
#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// Polls the recorder while a spoken Margin records and keeps `MarginCaptureSupervisor` informed (#937).
///
/// Every decision is the supervisor's. This type only reads the recorder, carries out the one action
/// the supervisor can ask for (restart the recorder), and reports health changes, so the screen can
/// say "Recording" only while audio is really arriving.
@MainActor
final class MarginCaptureWatcher {
    typealias HealthChange = (_ health: MarginCaptureSupervisor.Health, _ restarts: Int) -> Void

    static let pollIntervalMs = 250

    private var supervisor: MarginCaptureSupervisor?
    private var reading: () -> RecordingCaptureReading? = { nil }
    private var restart: () throws -> Void = {}
    private var changed: HealthChange = { _, _ in }
    private var holdRecorder: () -> Void = {}
    private var releaseRecorder: (_ afterSeconds: TimeInterval) -> Void = { _ in }
    private var pollTask: Task<Void, Never>?
    private var lastReported: (health: MarginCaptureSupervisor.Health, restarts: Int, keepable: Bool)?
    private let autoPoll: Bool
    private var startedAtMs = 0
    private var lastRouteChangeAtMs: Int?
    private var routeObserver: NSObjectProtocol?
    private let notificationCenter: NotificationCenter
    private let readyCue: MarginReadyCuePlaying
    private var readyCueGate = MarginReadyCueGate()
    /// What the ready cue did for this recording ("played", "skipped:..."), nil until capture is verified (#1594).
    private(set) var readyCueResult: String?
    /// Milliseconds on a clock that only moves forward. Tests replace it.
    var nowMs: () -> Int

    /// Tests pass `autoPoll: false` and call `tick()` themselves.
    init(
        autoPoll: Bool = true,
        notificationCenter: NotificationCenter = .default,
        readyCue: MarginReadyCuePlaying = MarginReadyCuePlayer(),
        nowMs: @escaping () -> Int = { Int((ProcessInfo.processInfo.systemUptime * 1_000).rounded()) }
    ) {
        self.autoPoll = autoPoll
        self.notificationCenter = notificationCenter
        self.readyCue = readyCue
        self.nowMs = nowMs
    }

    var isWatching: Bool { supervisor != nil }
    var health: MarginCaptureSupervisor.Health? { supervisor?.health }
    var restarts: Int { supervisor?.restarts ?? 0 }
    /// Enough audio is already captured that stopping now still leaves something worth saving.
    var hasKeepableAudio: Bool { supervisor?.hasKeepableAudio ?? false }
    /// Try again restarts the recorder, which deletes what it has taken in. It is offered only while
    /// there is nothing worth keeping (audit P1 on #939).
    var canRetry: Bool { supervisor != nil && !hasKeepableAudio }
    /// The most audio the current recorder has reported, for the diagnostics log.
    var capturedMs: Int { supervisor?.capturedMs ?? 0 }
    /// Milliseconds since the recording began, for the diagnostics log.
    var elapsedMs: Int { supervisor == nil ? 0 : max(0, nowMs() - startedAtMs) }
    /// Milliseconds since the audio route last changed during this recording, nil when it has not (#1708).
    var msSinceRouteChange: Int? { lastRouteChangeAtMs.map { max(0, nowMs() - $0) } }
    /// The final diagnostics line for this recording is written (once per recording).
    var finalRecorded = false

    /// Begins judging a recording that has just started, and polls until `stop()`.
    func start(
        reading: @escaping () -> RecordingCaptureReading?,
        restart: @escaping () throws -> Void,
        changed: @escaping HealthChange,
        holdRecorder: @escaping () -> Void = {},
        releaseRecorder: @escaping (_ afterSeconds: TimeInterval) -> Void = { _ in }
    ) {
        stop()
        self.reading = reading
        self.restart = restart
        self.changed = changed
        self.holdRecorder = holdRecorder
        self.releaseRecorder = releaseRecorder
        startedAtMs = nowMs()
        supervisor = MarginCaptureSupervisor(beganAtMs: startedAtMs)
        lastReported = nil
        finalRecorded = false
        lastRouteChangeAtMs = nil
        readyCueGate = MarginReadyCueGate()
        readyCueResult = nil
        observeRouteChanges()
        tick()
        guard autoPoll else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.pollIntervalMs))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// One poll: read the recorder, ask the supervisor, and carry out a restart if it asks for one.
    func tick() {
        guard var current = supervisor else { return }
        let now = nowMs()
        if current.observe(reading(), nowMs: now) == .restartCapture {
            restartNow(&current)
        }
        supervisor = current
        cueIfCaptureVerified(current)
        report()
    }

    /// The ready cue (#1594): once per recording, and only after the recorder has really taken audio in, so the
    /// listener hears it exactly when speaking is safe. It sounds before `changed` runs, so the diagnostics line
    /// written for that health change can say what it did. The recorder is held still while the cue plays, because on
    /// the built-in speaker it would hear the cue and the cue would open the saved Margin.
    private func cueIfCaptureVerified(_ current: MarginCaptureSupervisor) {
        guard readyCueGate.shouldCue(health: current.health, capturedMs: current.capturedMs) else { return }
        holdRecorder()
        let result = readyCue.playReadyCue()
        readyCueResult = result
        releaseRecorder(result == "played" ? MarginReadyCueHold.seconds : 0)
    }

    /// The listener asked to try again after the capture failed: restart now, then judge afresh.
    ///
    /// A restart deletes the recorder's file, and the screen's Try again comes from the last poll, which
    /// can be old. So the recorder is read again here, and nothing is restarted over audio worth keeping.
    /// Returns whether a restart was attempted: false when the recording holds audio worth keeping.
    @discardableResult
    func retry() -> Bool {
        guard var current = supervisor else { return false }
        _ = current.observe(reading(), nowMs: nowMs())
        guard !current.hasKeepableAudio else {
            supervisor = current
            report()
            return false
        }
        current.listenerRetry(nowMs: nowMs())
        restartNow(&current)
        supervisor = current
        cueIfCaptureVerified(current)
        report()
        return true
    }

    /// Starts a new recorder. If the client refuses (the finalized file holds audio) or fails, the
    /// capture is not capturing, and the supervisor learns what the recorder now holds.
    private func restartNow(_ current: inout MarginCaptureSupervisor) {
        do {
            try restart()
            current.captureRestarted(nowMs: nowMs())
        } catch {
            current.restartFailed()
            _ = current.observe(reading(), nowMs: nowMs())
        }
    }

    /// Whether the recording that would be saved now holds anything.
    func saveVerdict() -> MarginCaptureSupervisor.SaveVerdict {
        supervisor?.saveVerdict(reading: reading(), nowMs: nowMs()) ?? .save
    }

    /// Whether the recording a call or lost headphones just stopped holds anything. Not a fresh reading:
    /// the recorder is already stopped (see `MarginCaptureSupervisor.interruptionVerdict`).
    func interruptionVerdict() -> MarginCaptureSupervisor.SaveVerdict {
        supervisor?.interruptionVerdict(nowMs: nowMs()) ?? .saveCutShort
    }

    /// The headset can answer a route change with a transport command the listener never pressed (#1708).
    /// Called by the observer below; tests call it directly.
    func routeChanged() {
        guard supervisor != nil else { return }
        lastRouteChangeAtMs = nowMs()
    }

    private func observeRouteChanges() {
        #if canImport(AVFoundation) && os(iOS)
        removeRouteObserver()
        routeObserver = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        }
        #endif
    }

    private func removeRouteObserver() {
        if let routeObserver { notificationCenter.removeObserver(routeObserver) }
        routeObserver = nil
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        removeRouteObserver()
        lastRouteChangeAtMs = nil
        supervisor = nil
        lastReported = nil
        reading = { nil }
        restart = {}
        changed = { _, _ in }
        holdRecorder = {}
        releaseRecorder = { _ in }
    }

    private func report() {
        guard let health = supervisor?.health else { return }
        let restarts = supervisor?.restarts ?? 0
        let keepable = supervisor?.hasKeepableAudio ?? false
        guard lastReported?.health != health || lastReported?.restarts != restarts || lastReported?.keepable != keepable else { return }
        lastReported = (health, restarts, keepable)
        changed(health, restarts)
    }
}
