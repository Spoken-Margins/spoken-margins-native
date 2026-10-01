import Foundation
import SessionKit
#if canImport(MetricKit)
import MetricKit
#endif

/// Writes how often iOS ended the app for memory to Diagnostics as `memoryExits` (#122), from MetricKit's
/// daily app-exit report. Reports already delivered are read at launch; new ones arrive about once a day.
#if canImport(MetricKit)
final class MemoryExitMetricsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let diagnosticsKey = "memoryExits"

    // Set once on the main actor in `start`, before MetricKit can call back.
    private var publish: (@MainActor (String) -> Void)?

    @MainActor
    func start(publish: @escaping @MainActor (String) -> Void) {
        self.publish = publish
        let manager = MXMetricManager.shared
        manager.add(self)
        if let line = Self.diagnosticsLine(forPayloadJSON: manager.pastPayloads.map { $0.jsonRepresentation() }) {
            publish(line)
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let line = Self.diagnosticsLine(forPayloadJSON: payloads.map { $0.jsonRepresentation() }),
              let publish else { return }
        Task { @MainActor in publish(line) }
    }

    /// The line for the newest report that has an app-exit section; reports arrive oldest first.
    static func diagnosticsLine(forPayloadJSON payloads: [Data]) -> String? {
        payloads.lazy.reversed().compactMap(MemoryExitCounts.init(metricPayloadJSON:)).first?.diagnosticsLine
    }
}
#endif
