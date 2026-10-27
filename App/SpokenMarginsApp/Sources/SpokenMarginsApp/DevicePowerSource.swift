import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// Whether the phone is on external power, readable from any thread. The render-ahead policy decides on it (#2703:
/// a charging phone renders further ahead), and renders ask from background threads, where `UIDevice` can't be read.
protocol ExternalPowerSource: Sendable {
    /// True when charging or full on power, false on battery, nil when the phone can't tell (the simulator).
    var isOnExternalPower: Bool? { get }
}

/// The app's one power source: battery monitoring is switched on at launch, and the main actor keeps a lock-protected
/// copy of the state current from `UIDevice.batteryStateDidChangeNotification`, so any thread reads the latest value.
final class DevicePowerSource: ExternalPowerSource, @unchecked Sendable {
    static let app = DevicePowerSource()

    /// What iOS reports, mapped so tests and non-iOS builds needn't name `UIDevice.BatteryState`.
    enum BatteryState: Sendable { case unknown, unplugged, charging, full }

    private let lock = NSLock()
    private var state: BatteryState = .unknown
    private var observer: NSObjectProtocol?

    var isOnExternalPower: Bool? {
        switch lock.withLock({ state }) {
        case .charging, .full: true
        case .unplugged: false
        case .unknown: nil
        }
    }

    /// Records a state iOS reported. The notification and the first read call it; tests call it directly.
    func record(_ batteryState: BatteryState) {
        lock.withLock { state = batteryState }
    }

    /// Switches battery monitoring on, reads the state once and follows its changes. Safe to call more than once.
    @MainActor
    func startMonitoring() {
        #if canImport(UIKit) && os(iOS)
        guard observer == nil else { return }
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.record(Self.map(UIDevice.current.batteryState)) }
        }
        record(Self.map(device.batteryState))
        #endif
    }

    #if canImport(UIKit) && os(iOS)
    static func map(_ state: UIDevice.BatteryState) -> BatteryState {
        switch state {
        case .charging: .charging
        case .full: .full
        case .unplugged: .unplugged
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }
    #endif
}
