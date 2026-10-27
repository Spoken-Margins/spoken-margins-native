import Foundation
import SessionKit

/// Reads this device's model identifier for the voice catalog's chip floor (#2700). The mapping from
/// identifier to chip is SessionKit's `VoiceDeviceFloor`, tested on the host; this only asks the system.
enum VoiceDeviceProbe {
    /// `iPhone13,2` on a phone. In the simulator, the simulated model (`SIMULATOR_MODEL_IDENTIFIER`), since
    /// `uname` reports the Mac's `arm64` there. An iPad app on a Mac or Vision Pro reports `Mac…` or
    /// `RealityDevice…` through the same call, both Apple silicon.
    static func machineIdentifier(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        #if targetEnvironment(simulator)
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty { return simulated }
        #endif
        if ProcessInfo.processInfo.isiOSAppOnMac { return "Mac,1" }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The A-series generation, or nil when the identifier isn't one the table knows (floored voices then
    /// stay off, by `VoiceDeviceFloor.allows`).
    static func chipGeneration() -> Int? {
        VoiceDeviceFloor.generation(ofMachine: machineIdentifier())
    }
}
