import Foundation

/// What the Export Sessions screen reports. `sharedFileNames` is filled only after the share sheet says the
/// files went somewhere; until then (or if the listener cancels) only build failures are listed (#1528).
struct BatchSessionExportResult: Equatable {
    let sharedFileNames: [String]
    let failures: [String]
    let activityType: String?
}
