import Foundation

/// #4715: whether a request to a worker that runs one job at a time (the private episode map) starts now, is refused
/// with the listener's "already being prepared" warning, or waits its turn. `HeldTranscriptionRetries.settle` runs every
/// held retry in one turn on Allow, so with two held maps the second found the worker busy, warned the listener about
/// something they never asked for, and was lost (the audit on #5124, `e1eeb7c`, finding 2). A held retry that finds the
/// worker busy now waits, quietly, and starts when the running job ends; the listener's own request keeps the warning.
public struct OneAtATimeStarts<Request> {
    public enum Decision: Equatable, Sendable {
        /// Start it now.
        case start
        /// The listener asked while a job runs: tell them, as before.
        case refuseBusy
        /// A held retry while a job runs: it starts after the running job ends.
        case waitsItsTurn
    }

    private var waiting: [(key: String, request: Request)] = []

    public init() {}

    /// The keys waiting their turn, oldest first.
    public var waitingKeys: [String] { waiting.map(\.key) }

    /// Decides `request` under `key`. A waiting retry for the same key is replaced by a later one, keeping its place, and
    /// dropped when the listener's own request for that key starts, since that request covers it.
    public mutating func offer(_ request: Request, key: String, isHeldRetry: Bool, busy: Bool) -> Decision {
        guard busy else {
            waiting.removeAll { $0.key == key }
            return .start
        }
        guard isHeldRetry else { return .refuseBusy }
        if let index = waiting.firstIndex(where: { $0.key == key }) {
            waiting[index] = (key, request)
        } else {
            waiting.append((key, request))
        }
        return .waitsItsTurn
    }

    /// The next waiting request, taken off the list, once the worker is free; nil while it is busy or nothing waits.
    public mutating func next(busy: Bool) -> Request? {
        guard !busy, !waiting.isEmpty else { return nil }
        return waiting.removeFirst().request
    }
}
