import Foundation

/// The one order a Library folder's files are listed, numbered and played in (#3769). Relative paths are compared one
/// component at a time, each with `localizedStandardCompare` on its NFC form, so "2.pdf" comes before "10.pdf", "a.pdf" and
/// "A.pdf" sit together, and "Disc 1/x.pdf" comes before "Disc 1.5/y.pdf". A shorter path that is a prefix of a longer one
/// comes first. Two paths that compare equal that way fall back to a plain comparison of their NFC strings, so the order is
/// total and the same on every run. The walk, the folder record and the folder screen all call this, so they cannot disagree.
public enum NaturalPathOrder {
    /// A path's components, each in NFC, with empty parts (a doubled or leading slash) dropped.
    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).precomposedStringWithCanonicalMapping }
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for (a, b) in zip(left, right) {
            let result = a.localizedStandardCompare(b)
            if result != .orderedSame { return result }
        }
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        let a = left.joined(separator: "/")
        let b = right.joined(separator: "/")
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    public static func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }
}
