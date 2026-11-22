import Foundation

/// The order collections are listed in (#4343, #3769): the Library's Collections view among collections of equal
/// standing, Add to Collection's picker, and the Margins tab's scope.
public enum LibraryCollectionScope {
    /// Alphabetical, localized and case-insensitive, ties by id so the order never shuffles between launches.
    public static func chipOrder(_ collections: [ItemCollection]) -> [ItemCollection] {
        collections.sorted { lhs, rhs in
            let ordered = lhs.name.localizedStandardCompare(rhs.name)
            return ordered == .orderedSame ? lhs.id < rhs.id : ordered == .orderedAscending
        }
    }
}
