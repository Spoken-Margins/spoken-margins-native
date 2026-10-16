import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Writes thermal state changes and memory warnings to Diagnostics as `app.thermal_state` and
/// `app.memory_warning` events (#1682), each with whether the app was in the background. The event's own
/// time is in the log. Until now the export carried the thermal level only on fallback lines, so a phone
/// that ran hot, or was told to free memory, left no trace unless a fallback happened at that moment.
/// It watches the system from outside, so `Gate1AppModel` doesn't grow.
@MainActor
final class SystemConditionRecorder {
    static let thermalKind = "app.thermal_state"
    static let memoryWarningKind = "app.memory_warning"

    private let record: @MainActor (_ kind: String, _ fields: [String: String]) -> Void
    private let isInBackground: @MainActor () -> Bool
    private let readThermalState: () -> ProcessInfo.ThermalState
    private var lastThermalState: ProcessInfo.ThermalState
    private var subscriptions: Set<AnyCancellable> = []

    init(
        record: @escaping @MainActor (_ kind: String, _ fields: [String: String]) -> Void,
        isInBackground: @escaping @MainActor () -> Bool = SystemConditionRecorder.applicationIsInBackground,
        thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    ) {
        self.record = record
        self.isInBackground = isInBackground
        self.readThermalState = thermalState
        self.lastThermalState = thermalState()
    }

    static func applicationIsInBackground() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .background
        #else
        return false
        #endif
    }

    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    func start() {
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recordThermalChange() }
            .store(in: &subscriptions)
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in self?.recordMemoryWarning() }
            .store(in: &subscriptions)
        #endif
    }

    /// Nothing is written when the state is the one already recorded.
    func recordThermalChange() {
        let state = readThermalState()
        guard state != lastThermalState else { return }
        record(Self.thermalKind, [
            "state": Self.label(state),
            "previous": Self.label(lastThermalState),
            "background": String(isInBackground()),
        ])
        lastThermalState = state
    }

    func recordMemoryWarning() {
        record(Self.memoryWarningKind, ["background": String(isInBackground())])
    }
}
