import Foundation

/// Which Margins the podcast Now view lists, and the countdown to the next one (#447).
///
/// The Now view shows up to `defaultLimit` Margins nearest the playhead, own and shared, in listening order. The
/// first Margin ahead of the playhead says how long until it plays ("in 1:20"), counting down while playing. A
/// Margin whose position is only approximate says so ("in about 1:20") instead of promising a time it can't keep.
/// Positions are in seconds. The view only draws what this returns.
public enum PlaybackNowMargins {
    /// How many Margins the Now view lists.
    public static let defaultLimit = 4

    public enum Origin: Sendable, Equatable {
        /// The listener's own Margin.
        case own
        /// A Margin shared with the listener.
        case shared
    }

    /// A Margin at a position on the source's clock, in seconds.
    public struct Margin: Sendable, Equatable {
        public let id: String
        public let position: Double
        public let origin: Origin
        /// The position is a rough match (ads can differ between copies), not a verified one.
        public let isApproximate: Bool

        public init(id: String, position: Double, origin: Origin, isApproximate: Bool = false) {
            self.id = id
            self.position = position
            self.origin = origin
            self.isApproximate = isApproximate
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let position: Double
        public let origin: Origin
        public let isApproximate: Bool
        /// "in 1:20" for the next Margin ahead of the playhead; nil on every other row.
        public let countdown: String?

        public init(id: String, position: Double, origin: Origin, isApproximate: Bool, countdown: String?) {
            self.id = id
            self.position = position
            self.origin = origin
            self.isApproximate = isApproximate
            self.countdown = countdown
        }
    }

    /// The Margins to list, in listening order (earliest first, ties by id).
    ///
    /// The next Margin ahead of the playhead is always listed, even when `limit` Margins sit closer behind it. The
    /// remaining places go to the Margins nearest the playhead in either direction. Margins at the playhead count
    /// as behind it. Every Margin sharing the next position shows the same countdown. Margins with no usable
    /// position are left out.
    public static func rows(playhead: Double, margins: [Margin], limit: Int = defaultLimit) -> [Row] {
        guard limit > 0, playhead.isFinite else { return [] }
        let usable = margins.filter { $0.position.isFinite }
        let nextPosition = usable.filter { $0.position > playhead }.map(\.position).min()

        func nearer(_ lhs: Margin, _ rhs: Margin) -> Bool {
            let lhsDistance = abs(lhs.position - playhead)
            let rhsDistance = abs(rhs.position - playhead)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            // Equally close: the one ahead first, as it is the one still to come.
            if (lhs.position > playhead) != (rhs.position > playhead) { return lhs.position > playhead }
            return lhs.id < rhs.id
        }

        let upNext = usable.filter { $0.position == nextPosition }.sorted { $0.id < $1.id }
        let others = usable.filter { $0.position != nextPosition }.sorted(by: nearer)
        let chosen = (upNext + others).prefix(limit)

        return chosen
            .sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
            .map { margin in
                let countdown = margin.position == nextPosition
                    ? countdownText(secondsAhead: margin.position - playhead, isApproximate: margin.isApproximate)
                    : nil
                return Row(id: margin.id, position: margin.position, origin: margin.origin,
                           isApproximate: margin.isApproximate, countdown: countdown)
            }
    }

    /// "in 1:20", or "in about 1:20" when the position is approximate. Rounds up, so a Margin still ahead never
    /// reads "in 0:00". An hour or more reads "in 1:05:00".
    public static func countdownText(secondsAhead: Double, isApproximate: Bool) -> String {
        let seconds = Int(min(max(1, secondsAhead.rounded(.up)), 8_640_000))
        let clock = seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return isApproximate ? "in about \(clock)" : "in \(clock)"
    }
}
