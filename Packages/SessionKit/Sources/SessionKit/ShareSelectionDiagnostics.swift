import Foundation

/// How the Share sheet got its starting selection (#4173).
public enum ShareOpenedFrom: String, Codable, CaseIterable, Sendable {
    /// Some Margin on the item was starred, so only the starred ones started selected.
    case starred
    /// Nothing was starred, so every Margin started selected.
    case all
    /// "Send replies to <friend>": the replies start selected.
    case replies
    /// "Share this Margin": one Margin.
    case single
}

/// The `share.selection` Diagnostics line, written once per send tap (#4173). Counts, a place name and seconds only:
/// no Margin id, words, friend or item. It lets a phone check read whether starring while listening replaced sorting
/// in the review.
public enum ShareSelectionDiagnostics {
    public static let kind = "share.selection"

    /// One Margin on the sheet, reduced to the two facts the line counts.
    public struct Margin: Equatable, Sendable {
        public var isStarred: Bool
        /// Included by the sender and shareable, so it will be written into the packet.
        public var isWritten: Bool

        public init(isStarred: Bool, isWritten: Bool) {
            self.isStarred = isStarred
            self.isWritten = isWritten
        }
    }

    public static func fields(
        opened: ShareOpenedFrom,
        margins: [Margin],
        secondsInSheet: TimeInterval,
        tally: ShareStarTally
    ) -> [String: String] {
        let written = margins.filter(\.isWritten)
        return [
            "opened": opened.rawValue,
            "included": String(written.count),
            "starredIncluded": String(written.filter(\.isStarred).count),
            "starredLeftOut": String(margins.filter { $0.isStarred && !$0.isWritten }.count),
            "unstarredIncluded": String(written.filter { !$0.isStarred }.count),
            "secondsInSheet": String(Int(max(0, secondsInSheet).rounded())),
            "starsNow": String(tally.starsNow),
            "starsPlayerMargins": String(tally.starsPlayerMargins),
            "starsElsewhere": String(tally.starsElsewhere),
            "unstars": String(tally.unstars)
        ]
    }

    /// How a sheet got its starting selection, from what it was asked to list.
    public static func opened(isReplyBack: Bool, isSingleMargin: Bool, hasStarredCandidates: Bool) -> ShareOpenedFrom {
        if isReplyBack { return .replies }
        if isSingleMargin { return .single }
        return hasStarredCandidates ? .starred : .all
    }
}
