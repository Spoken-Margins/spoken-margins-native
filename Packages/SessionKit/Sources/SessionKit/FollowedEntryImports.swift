import Foundation

/// The Following episodes being fetched into the Library, and which of those fetches a ▶ tap asked to play (#5328).
///
/// A Following row shows "Adding…" for a swipe Add and a spinner on ▶ for a ▶ tap. Both used to be read from the one set
/// of fetching entries, so a swipe Add on the episode ▶ plays (the usual case) drew the ▶ spinner and never "Adding…".
/// This keeps the two apart, and lets a ▶ tap on an episode a swipe is already adding play it when it lands, instead of
/// being dropped by the one-fetch-per-entry rule.
public struct FollowedEntryImports: Equatable, Sendable {
    /// Every entry with a fetch running, whoever started it.
    public private(set) var importing: Set<String> = []
    /// The fetches a ▶ tap started, or joined.
    public private(set) var playing: Set<String> = []
    /// A ▶ tap that joined a fetch already running: its request token, checked when the fetch lands.
    private var joinedPlay: [String: CurrentRequest.Token] = [:]

    public init() {}

    /// Whether a fetch for `id` is running.
    public func contains(_ id: String) -> Bool { importing.contains(id) }

    /// A fetch for `id` was asked for. True when it should start; false when one is already running, and the request
    /// rides on that one (so the item lands in the Library once).
    @discardableResult
    public mutating func begin(_ id: String, play: Bool) -> Bool {
        guard importing.insert(id).inserted else { return false }
        if play { playing.insert(id) }
        return true
    }

    /// Whether a ▶ tap on `id` should join the running fetch: one is running and no ▶ has asked for it yet.
    public func canJoinForPlay(_ id: String) -> Bool { importing.contains(id) && !playing.contains(id) }

    /// A ▶ tap joined the running fetch for `id`; `token` is its play request, so a later open or start still wins.
    public mutating func joinForPlay(_ id: String, token: CurrentRequest.Token) {
        guard canJoinForPlay(id) else { return }
        playing.insert(id)
        joinedPlay[id] = token
    }

    /// The item for `id` has landed: hands back the token of a ▶ tap that joined the fetch, once, so the caller can play
    /// the item at once instead of after the fetch's bookkeeping. ▶ keeps its spinner until `end`.
    public mutating func takeJoinedPlay(_ id: String) -> CurrentRequest.Token? {
        joinedPlay.removeValue(forKey: id)
    }

    /// The fetch for `id` ended. Returns the token of a ▶ tap that joined it, if one did: the caller plays the saved item
    /// when that request is still the listener's latest.
    @discardableResult
    public mutating func end(_ id: String) -> CurrentRequest.Token? {
        importing.remove(id)
        playing.remove(id)
        return joinedPlay.removeValue(forKey: id)
    }

    /// ▶ shows its spinner: a ▶ tap is waiting on this episode's fetch.
    public func isPlayStarting(_ id: String?) -> Bool { id.map(playing.contains) ?? false }

    /// The status slot says "Adding…": the episode is being fetched and no ▶ tap is waiting on it.
    public func isAdding(_ id: String?) -> Bool {
        guard let id else { return false }
        return importing.contains(id) && !playing.contains(id)
    }
}
