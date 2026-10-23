import Foundation

/// The listener's latest request of one kind, so a late async completion can tell whether it still
/// counts (#2124, #2125, #2126). Starting a request makes every older token stale; cancelling makes the
/// outstanding one stale. A completion checks its token after every await, before it acts: a fetch that
/// lands after the listener started something else, a voice preview that finishes rendering after they
/// pressed play, or a microphone grant that arrives after they cancelled.
public struct CurrentRequest: Sendable, Equatable {
    public struct Token: Hashable, Sendable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var outstanding = false

    public init() {}

    /// Starts a new request. Every token handed out before is stale from now on.
    public mutating func begin() -> Token {
        generation &+= 1
        outstanding = true
        return Token(generation: generation)
    }

    /// The listener moved on or cancelled: the outstanding token, if any, is stale.
    public mutating func cancel() {
        generation &+= 1
        outstanding = false
    }

    /// Whether a request is still waiting on its completion.
    public var isPending: Bool { outstanding }

    /// Whether `token` is still the listener's latest, unfinished request.
    public func isCurrent(_ token: Token) -> Bool {
        outstanding && token.generation == generation
    }

    /// Consumes `token` if it is current, so the completion acts at most once. Returns false for a stale
    /// or already-finished token; the caller then drops its result.
    @discardableResult
    public mutating func finish(_ token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        outstanding = false
        return true
    }
}
