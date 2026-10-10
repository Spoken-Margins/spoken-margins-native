import Foundation

/// The skip distances a listener can choose for audio that plays on the clock (podcasts and other
/// media), and the unit string the engine takes for them.
public enum MediaSkipRule {
    public static let supportedSeconds = [10, 15, 30, 45, 60]
    public static let defaultSeconds = 15

    /// `seconds` when it is one of `supportedSeconds`, else `defaultSeconds`. A value that was never
    /// stored reads as 0, so it lands on the default too.
    public static func validated(_ seconds: Int) -> Int {
        supportedSeconds.contains(seconds) ? seconds : defaultSeconds
    }

    /// The engine's skip unit for `seconds`, for example `time_45s`.
    public static func unit(seconds: Int) -> String {
        "time_\(validated(seconds))s"
    }
}
