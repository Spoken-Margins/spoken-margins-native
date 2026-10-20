import Foundation

/// Times a transport tap against the playback status that answers it (#2099): the milliseconds from the
/// tap to the first change of status after it. The model reports each in-app tap and each status change;
/// this decides which change belongs to which tap. Only the command and status names are kept.
public struct TapToStateTracker: Sendable, Equatable {
    public static let eventKind = "transport.state"

    /// A status change later than this after the tap is not attributed to it.
    public static let windowSeconds: TimeInterval = 30

    public struct Tap: Sendable, Equatable {
        public let command: String
        public let status: String
        public let startedAt: TimeInterval
    }

    public private(set) var pending: Tap?

    public init() {}

    /// A tap at `at` (seconds of uptime) while the status reads `status`. A newer tap replaces one still waiting.
    public mutating func tapped(command: String, status: String, at: TimeInterval) {
        pending = Tap(command: command, status: status, startedAt: at)
    }

    /// The status read `status` at `at`. Returns the `transport.state` fields when that ends the wait of a
    /// tap, and nil when nothing waits, the status is the one the tap saw, or the tap is too old.
    public mutating func statusChanged(to status: String, at: TimeInterval) -> [String: String]? {
        guard let tap = pending else { return nil }
        if at - tap.startedAt > Self.windowSeconds {
            pending = nil
            return nil
        }
        guard status != tap.status else { return nil }
        pending = nil
        return [
            "command": tap.command,
            "from": tap.status,
            "to": status,
            "tapToStateMs": String(Int(((at - tap.startedAt) * 1000).rounded())),
        ]
    }
}
