import Foundation
import SessionKit
#if canImport(MetricKit)
import MetricKit
#endif

/// Records how the previous run ended as one `app.previous_exit` Diagnostics event (#1682), from what iOS
/// tells MetricKit: crash, CPU-exception and hang reports, and the daily background-exit counts (CPU
/// limit, memory, watchdog). Reports that MetricKit already delivered are read once at launch, off the
/// main thread. One that arrives later in the run adds its own event, marked `delivery: late`. The event
/// holds counts and system codes only (`PreviousRunExit`), nothing that links it to the listener.
#if canImport(MetricKit)
final class PreviousRunExitRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    typealias Record = @MainActor (_ kind: String, _ fields: [String: String]) -> Void

    private static let diagnosticsKey = "previousRunExit.diagnosticsThrough"
    private static let metricsKey = "previousRunExit.metricsThrough"

    private let defaults: UserDefaults
    // Set once on the main actor in `start`, before MetricKit can call back.
    private var record: Record?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Sets where events go. Split from `start` so a test can feed `deliver` without MetricKit.
    @MainActor
    func attach(_ record: @escaping Record) {
        self.record = record
    }

    @MainActor
    func start(record: @escaping Record) {
        attach(record)
        MXMetricManager.shared.add(self)
        Task.detached(priority: .utility) { [weak self] in
            let manager = MXMetricManager.shared
            let diagnostics = manager.pastDiagnosticPayloads.map { $0.jsonRepresentation() }
            let metrics = manager.pastPayloads.map { $0.jsonRepresentation() }
            await self?.deliver(diagnostics: diagnostics, metrics: metrics, isLaunch: true)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let diagnostics = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor [weak self] in self?.deliver(diagnostics: diagnostics, metrics: [], isLaunch: false) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let metrics = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor [weak self] in self?.deliver(diagnostics: [], metrics: metrics, isLaunch: false) }
    }

    /// The launch delivery always writes an event, so an export that says `none_reported` can be told from
    /// one whose launch never got that far. A later delivery writes one only if it brought a new report.
    @MainActor
    func deliver(diagnostics: [Data], metrics: [Data], isLaunch: Bool) {
        guard let record else { return }
        let exit = PreviousRunExit.summarize(diagnosticPayloads: diagnostics, metricPayloads: metrics, seen: seen())
        remember(exit.seen)
        guard isLaunch || exit.newReports > 0 else { return }
        var fields = exit.fields
        fields["delivery"] = isLaunch ? "launch" : "late"
        record(PreviousRunExit.eventKind, fields)
    }

    private func seen() -> PreviousRunExit.Seen {
        PreviousRunExit.Seen(diagnosticsThrough: defaults.string(forKey: Self.diagnosticsKey),
                             metricsThrough: defaults.string(forKey: Self.metricsKey))
    }

    private func remember(_ seen: PreviousRunExit.Seen) {
        defaults.set(seen.diagnosticsThrough, forKey: Self.diagnosticsKey)
        defaults.set(seen.metricsThrough, forKey: Self.metricsKey)
    }
}
#endif
