import Foundation
import SessionKit

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
    private var pollTask: Task<Void, Never>?
    private var lastReported: (health: MarginCaptureSupervisor.Health, restarts: Int)?
    private let autoPoll: Bool
    private var startedAtMs = 0
    /// Milliseconds on a clock that only moves forward. Tests replace it.
    var nowMs: () -> Int

    /// Tests pass `autoPoll: false` and call `tick()` themselves.
    init(
        autoPoll: Bool = true,
        nowMs: @escaping () -> Int = { Int((ProcessInfo.processInfo.systemUptime * 1_000).rounded()) }
    ) {
        self.autoPoll = autoPoll
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
    /// Milliseconds since the recording began, for the diagnostics log.
    var elapsedMs: Int { supervisor == nil ? 0 : max(0, nowMs() - startedAtMs) }

    /// Begins judging a recording that has just started, and polls until `stop()`.
    func start(
        reading: @escaping () -> RecordingCaptureReading?,
        restart: @escaping () throws -> Void,
        changed: @escaping HealthChange
    ) {
        stop()
        self.reading = reading
        self.restart = restart
        self.changed = changed
        startedAtMs = nowMs()
        supervisor = MarginCaptureSupervisor(beganAtMs: startedAtMs)
        lastReported = nil
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
            do {
                try restart()
                current.captureRestarted(nowMs: nowMs())
            } catch {
                current.restartFailed()
            }
        }
        supervisor = current
        report()
    }

    /// The listener asked to try again after the capture failed: restart now, then judge afresh.
    func retry() {
        guard canRetry, var current = supervisor else { return }
        current.listenerRetry(nowMs: nowMs())
        do {
            try restart()
            current.captureRestarted(nowMs: nowMs())
        } catch {
            current.restartFailed()
        }
        supervisor = current
        report()
    }

    /// Whether the recording that would be saved now holds anything.
    func saveVerdict() -> MarginCaptureSupervisor.SaveVerdict {
        supervisor?.saveVerdict(reading: reading(), nowMs: nowMs()) ?? .save
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        supervisor = nil
        lastReported = nil
        reading = { nil }
        restart = {}
        changed = { _, _ in }
    }

    private func report() {
        guard let health = supervisor?.health else { return }
        let restarts = supervisor?.restarts ?? 0
        guard lastReported?.health != health || lastReported?.restarts != restarts else { return }
        lastReported = (health, restarts)
        changed(health, restarts)
    }
}
