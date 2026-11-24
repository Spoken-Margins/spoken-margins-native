import Foundation

/// The friend's side of opened marks (#5275): each share link this app opened, whether its server offers opened
/// marks, its opened-token, and whether the mark was sent. Kept in UserDefaults under
/// `shareLinkOpenedSignalled.v1` and dropped 31 days after the import, a day past the link's own life.
public struct FriendLinkSignal: Codable, Equatable, Sendable {
    public var importedAt: Date
    public var offered: Bool
    public var token: String
    public var sent: Bool
}

public struct FriendLinkSignals: @unchecked Sendable {
    public static let defaultsKey = "shareLinkOpenedSignalled.v1"
    public static let keep: TimeInterval = 31 * 24 * 60 * 60

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all(now: Date) -> [String: FriendLinkSignal] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([String: FriendLinkSignal].self, from: data) else { return [:] }
        return entries.filter { now.timeIntervalSince($0.value.importedAt) < Self.keep }
    }

    public func signal(for id: String, now: Date) -> FriendLinkSignal? {
        all(now: now)[id]
    }

    /// Records a link the app just opened. A link already signalled stays signalled; opening it again from a
    /// server that now offers marks updates `offered`.
    public func recordArrival(id: String, token: String, offered: Bool, now: Date) {
        var entries = all(now: now)
        if var existing = entries[id] {
            guard !existing.sent else { return }
            existing.offered = existing.offered || offered
            existing.token = token
            entries[id] = existing
        } else {
            entries[id] = FriendLinkSignal(importedAt: now, offered: offered, token: token, sent: false)
        }
        save(entries)
    }

    public func markSent(id: String, now: Date) {
        var entries = all(now: now)
        guard entries[id] != nil else { return }
        entries[id]?.sent = true
        save(entries)
    }

    private func save(_ entries: [String: FriendLinkSignal]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Sends the friend's opened marks when they press a start control (#5275). Fire and forget, after playback
/// starts, so it never delays audio. A link is sent once: a double tap sends one request, and a request that
/// fails (offline, the server says no) is sent again from the next start control.
@MainActor
public final class FriendLinkSignaller {
    private let signals: FriendLinkSignals
    private let client: ShareLinkOpenedClient
    private let defaults: UserDefaults
    private let ownLinkIDs: @MainActor () -> Set<String>
    private let now: @Sendable () -> Date
    private var inFlight: Set<String> = []

    public init(signals: FriendLinkSignals, client: ShareLinkOpenedClient, defaults: UserDefaults = .standard,
                ownLinkIDs: @escaping @MainActor () -> Set<String>, now: @escaping @Sendable () -> Date = Date.init) {
        self.signals = signals
        self.client = client
        self.defaults = defaults
        self.ownLinkIDs = ownLinkIDs
        self.now = now
    }

    /// Whether a mark for `id` may leave this device now.
    public static func shouldSignal(id: String, entry: FriendLinkSignal?, receiptsOn: Bool, ownLinkIDs: Set<String>, inFlight: Set<String>) -> Bool {
        guard receiptsOn, let entry, entry.offered, !entry.sent, ShareLinkOpenedToken.isValid(entry.token) else { return false }
        return !ownLinkIDs.contains(id) && !inFlight.contains(id)
    }

    /// Sends the marks for `ids` that may go. Returns the task, for tests to wait on; callers drop it.
    @discardableResult
    public func signal(ids: [String]) -> Task<Void, Never>? {
        let receiptsOn = ShareLinkOpenedPolicy.isOn(defaults)
        let own = ownLinkIDs()
        let entries = signals.all(now: now())
        var due: [(id: String, token: String)] = []
        for id in Set(ids).sorted() {
            guard Self.shouldSignal(id: id, entry: entries[id], receiptsOn: receiptsOn, ownLinkIDs: own, inFlight: inFlight),
                  let token = entries[id]?.token else { continue }
            inFlight.insert(id)
            due.append((id, token))
        }
        guard !due.isEmpty else { return nil }
        let client = client
        return Task { [weak self] in
            for link in due {
                let sent = await client.markOpened(id: link.id, token: link.token)
                self?.finish(id: link.id, sent: sent)
            }
        }
    }

    private func finish(id: String, sent: Bool) {
        inFlight.remove(id)
        if sent { signals.markSent(id: id, now: now()) }
    }
}
