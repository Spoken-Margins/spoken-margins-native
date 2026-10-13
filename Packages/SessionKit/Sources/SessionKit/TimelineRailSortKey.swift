import Foundation

/// Sort before rounding the percentage used for display (#448).
public struct TimelineRailSortKey: Comparable, Equatable, Sendable {
    public let position: Int
    public let rank: Int
    public let id: String
    public let precisePosition: Double?

    public init(position: Int, rank: Int, id: String, precisePosition: Double? = nil) {
        self.position = position
        self.rank = rank
        self.id = id
        self.precisePosition = precisePosition.flatMap { $0.isFinite ? $0 : nil }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let left = lhs.precisePosition ?? Double(lhs.position)
        let right = rhs.precisePosition ?? Double(rhs.position)
        if left != right { return left < right }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.id < rhs.id
    }

    public static func percent(position: Int?, length: Int?) -> Double? {
        guard let position, position >= 0, let length, length > 0 else { return nil }
        return min(100, Double(position) / Double(length) * 100)
    }
}
