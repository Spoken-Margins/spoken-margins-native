import Foundation

/// The one order a Library folder's files are listed and played in (#3769): "Chapter 2" before "Chapter 10",
/// and "Disc 1/Track 3" before "Disc 2/Track 1". Paths are compared one component at a time, each with
/// `localizedStandardCompare` on its NFC form, so a name typed with a combining accent sorts like the same name
/// typed with the single accented letter. A path that is a prefix of a longer one comes first. A tie falls back to
/// a plain comparison of the NFC strings, so two files never swap places from one run to the next.
public enum NaturalPathOrder {
    /// Compares two relative paths written with `/` between components.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for (a, b) in zip(left, right) {
            let natural = a.localizedStandardCompare(b)
            if natural != .orderedSame { return natural }
        }
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        // Same components under natural comparison (case or spacing variants): plain NFC comparison decides.
        for (a, b) in zip(left, right) where a != b { return a < b ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    public static func areInOrder(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    private static func components(_ path: String) -> [String] {
        path.precomposedStringWithCanonicalMapping.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
