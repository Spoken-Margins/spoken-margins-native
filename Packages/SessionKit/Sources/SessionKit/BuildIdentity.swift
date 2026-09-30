import Foundation

/// The app's version, build number and, for phone builds made by scripts/phone-build, the commit it
/// was built from. Settings and diagnostic exports show it, so an issue found on the phone can name
/// the exact build (#384).
public enum BuildIdentity {
    /// The Info.plist key scripts/phone-build fills through the SM_BUILD_COMMIT build setting.
    public static let commitInfoKey = "SMBuildCommit"

    /// "0.1 (29)", or "0.1 (29) · 1a2b3c4" when the build recorded its commit.
    public static func describe(info: [String: Any]) -> String {
        let version = nonEmpty(info["CFBundleShortVersionString"]) ?? "unknown"
        let build = nonEmpty(info["CFBundleVersion"]) ?? "unknown"
        guard let commit = nonEmpty(info[commitInfoKey]) else { return "\(version) (\(build))" }
        return "\(version) (\(build)) · \(commit.prefix(7))"
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.hasPrefix("$(") else { return nil }
        return text
    }
}
