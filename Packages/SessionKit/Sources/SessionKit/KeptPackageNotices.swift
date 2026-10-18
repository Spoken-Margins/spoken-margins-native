import Foundation

/// Remembers the shared-Margins files kept because they need a newer app (#1983): when each was first kept, and
/// the app version whose launch last told the listener, so the message comes once per app version and a file
/// nobody updates for expires after `retention`.
///
/// The first-kept date lives here, not in the file's modification date: a friend's file can be months old when it
/// is copied in, and it would expire at once.
public struct KeptPackageNotices {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// The most files kept at once; the oldest go first, so repeated shares can't grow the inbox without bound.
    public static let maximumKept = 5
    private static let defaultsKey = "keptPackageNotices.v1"

    private struct Entry: Codable, Equatable {
        var keptSince: Date
        var toldInVersion: String
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The marketing version and build, for example "0.1 (35)"; a different build tells the listener again.
    public static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// True when this launch has not yet told the listener about `payloadID`.
    public func shouldAnnounce(payloadID: String, appVersion: String) -> Bool {
        entries()[payloadID]?.toldInVersion != appVersion
    }

    /// Notes that the file was kept and the listener told, in `appVersion`. The first call sets the keep date.
    public func noteKept(payloadID: String, appVersion: String, now: Date) {
        var all = entries()
        let since = all[payloadID]?.keptSince ?? now
        all[payloadID] = Entry(keptSince: since, toldInVersion: appVersion)
        save(all)
    }

    /// True when the file is being kept for an update.
    public func isKept(payloadID: String) -> Bool {
        entries()[payloadID] != nil
    }

    /// The oldest kept files beyond `maximumKept`.
    public func overflowIDs() -> [String] {
        let oldestFirst = entries().sorted { $0.value.keptSince < $1.value.keptSince }.map(\.key)
        return Array(oldestFirst.dropLast(Self.maximumKept))
    }

    /// Drops the notes of files that are no longer in the inbox.
    public func forgetAll(except pendingIDs: Set<String>) {
        let all = entries()
        let stale = all.keys.filter { !pendingIDs.contains($0) }
        guard !stale.isEmpty else { return }
        save(all.filter { pendingIDs.contains($0.key) })
    }

    public func hasExpired(payloadID: String, now: Date) -> Bool {
        guard let since = entries()[payloadID]?.keptSince else { return false }
        return now.timeIntervalSince(since) > Self.retention
    }

    public func forget(payloadID: String) {
        var all = entries()
        guard all.removeValue(forKey: payloadID) != nil else { return }
        save(all)
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let all = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return all
    }

    private func save(_ all: [String: Entry]) {
        if all.isEmpty { defaults.removeObject(forKey: Self.defaultsKey); return }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
