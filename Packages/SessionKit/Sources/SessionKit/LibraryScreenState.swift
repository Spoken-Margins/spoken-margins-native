import Foundation

/// #1969: what a build that can't open the listener's existing Library tells them. It protects their data: the
/// words say the Library is safe and not to delete the app, and the Library tab shows them instead of the happy
/// "Your Library is ready" empty state, which invites new content into a store that can't be opened.
public struct LibraryAccessNote: Equatable, Sendable {
    public static let title = "Your Library is safe, but this version can't open it."
    public static let message = "Don't delete the app. Update Spoken Margins, then reopen it."

    /// The technical reason, for the "Details" disclosure.
    public let detail: String

    public init(accessError: String) {
        let marker = "Details: "
        if let range = accessError.range(of: marker) {
            detail = String(accessError[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            detail = accessError.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Which body the Library tab shows. The model's `libraryAccessError` outranks every other state.
public enum LibraryScreenState: Equatable, Sendable {
    case cannotOpen(LibraryAccessNote)
    case empty
    case caughtUp
    case noMatches
    case list

    public static func resolve(accessError: String?, itemCount: Int, isCaughtUp: Bool, visibleCount: Int) -> LibraryScreenState {
        if let accessError { return .cannotOpen(LibraryAccessNote(accessError: accessError)) }
        if itemCount == 0 { return .empty }
        if isCaughtUp { return .caughtUp }
        if visibleCount == 0 { return .noMatches }
        return .list
    }

    /// Adding content is off while the Library can't be opened, so nothing is written into a new empty store.
    public var allowsAddingContent: Bool {
        if case .cannotOpen = self { return false }
        return true
    }
}
