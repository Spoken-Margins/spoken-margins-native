import Foundation

/// Performance settings for Supertonic's four ONNX Runtime sessions (#2702).
///
/// Left unset, ONNX Runtime sizes its intra-op pool to every core, which on a
/// phone competes with the UI and heats the device. Kitten sets an explicit
/// count; Supertonic now does the same. The overrides exist only in DEBUG
/// builds, for side-by-side comparisons, and are never read in release.
enum SupertonicTuning {
    static let defaultIntraOpThreads: Int32 = 2
    /// Idle pool threads spin-wait by default, burning CPU that iOS counts against
    /// the background CPU limit (#2695). Sessions here run with a single-threaded
    /// inter-op path (no inter-op pool is created), so only intra-op spinning applies.
    static let allowSpinningKey = "session.intra_op.allow_spinning"
    static let allowSpinningValue = "0"
    static let intraOpThreadsRange: ClosedRange<Int32> = 1...8
    static let synthesisStepsRange: ClosedRange<Int> = 1...32

    static let threadsOverrideKey = "SM_SUPERTONIC_THREADS"
    static let stepsOverrideKey = "SM_SUPERTONIC_STEPS"

    /// Pure, so tests can feed it an environment. `allowOverrides` is false in release.
    static func intraOpThreads(environment: [String: String], allowOverrides: Bool) -> Int32 {
        guard allowOverrides, let raw = environment[threadsOverrideKey],
              let value = Int32(raw), intraOpThreadsRange.contains(value) else {
            return defaultIntraOpThreads
        }
        return value
    }

    static func synthesisSteps(requested: Int, environment: [String: String], allowOverrides: Bool) -> Int {
        guard allowOverrides, let raw = environment[stepsOverrideKey],
              let value = Int(raw), synthesisStepsRange.contains(value) else {
            return requested
        }
        return value
    }

    static var currentIntraOpThreads: Int32 {
        #if DEBUG
        return intraOpThreads(environment: ProcessInfo.processInfo.environment, allowOverrides: true)
        #else
        return defaultIntraOpThreads
        #endif
    }

    static func currentSynthesisSteps(requested: Int) -> Int {
        #if DEBUG
        return synthesisSteps(requested: requested, environment: ProcessInfo.processInfo.environment, allowOverrides: true)
        #else
        return requested
        #endif
    }
}
