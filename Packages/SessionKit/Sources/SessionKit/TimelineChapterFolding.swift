import Foundation

/// Which chapters of the Timeline rail the listener has folded (#3895).
///
/// The rail is one flat, ordered list. A chapter row starts a section that runs to the next chapter row, so
/// folding a dense chapter (many figures, tables and footnotes) hides its rows and leaves every chapter row
/// in place, which is what lets the listener reach the next chapter. Nothing is deleted: a folded chapter
/// says how many rows it holds, whether the playhead is in it, and whether anything new arrived in it.
///
/// Rows before the first chapter row belong to no section and are never hidden. A chapter row with nothing
/// under it has nothing to fold.
public struct TimelineChapterFolding: Equatable, Sendable {
    /// What the folding needs to know about one rail row, in rail order.
    public struct Row: Equatable, Sendable {
        public let id: String
        /// True for a chapter row: the rows that follow it, up to the next chapter row, are its section.
        public let isChapter: Bool
        /// A shared Margin the listener hasn't heard yet. Folding must not bury it silently.
        public let isNew: Bool

        public init(id: String, isChapter: Bool, isNew: Bool = false) {
            self.id = id
            self.isChapter = isChapter
            self.isNew = isNew
        }
    }

    /// What a folded chapter row tells the listener about the rows it hides.
    public struct HiddenSummary: Equatable, Sendable {
        public let hiddenCount: Int
        public let hasNew: Bool
        /// The playhead is on a hidden row, so the chapter is where the listener is.
        public let containsCurrent: Bool

        public init(hiddenCount: Int, hasNew: Bool, containsCurrent: Bool) {
            self.hiddenCount = hiddenCount
            self.hasNew = hasNew
            self.containsCurrent = containsCurrent
        }

        /// "5 rows hidden", "1 row hidden, new inside".
        public var text: String {
            let rows = hiddenCount == 1 ? "1 row hidden" : "\(hiddenCount) rows hidden"
            return hasNew ? "\(rows), new inside" : rows
        }
    }

    /// The ids of chapter rows the listener folded.
    public private(set) var foldedChapterIDs: Set<String>

    public init(foldedChapterIDs: Set<String> = []) {
        self.foldedChapterIDs = foldedChapterIDs
    }

    // MARK: Sections

    /// The rows under each chapter row, keyed by that chapter's id. A chapter with no rows under it is absent.
    public static func members(in rows: [Row]) -> [String: [Row]] {
        var result: [String: [Row]] = [:]
        var header: String?
        for row in rows {
            if row.isChapter {
                header = row.id
            } else if let header {
                result[header, default: []].append(row)
            }
        }
        return result
    }

    /// Whether this chapter row has anything under it to fold.
    public static func canFold(_ chapterID: String, in rows: [Row]) -> Bool {
        members(in: rows)[chapterID] != nil
    }

    // MARK: Folding

    public func isFolded(_ chapterID: String) -> Bool {
        foldedChapterIDs.contains(chapterID)
    }

    /// Fold or unfold a chapter. A chapter with nothing under it stays unfolded.
    public mutating func toggle(_ chapterID: String, in rows: [Row]) {
        if foldedChapterIDs.contains(chapterID) {
            foldedChapterIDs.remove(chapterID)
        } else if Self.canFold(chapterID, in: rows) {
            foldedChapterIDs.insert(chapterID)
        }
    }

    /// Forget chapters that are no longer on the rail or no longer have rows under them (a different item, or a
    /// rail rebuilt after an import), so a stale id never hides rows of a section it doesn't belong to.
    public mutating func prune(to rows: [Row]) {
        guard !foldedChapterIDs.isEmpty else { return }
        let foldable = Set(Self.members(in: rows).keys)
        foldedChapterIDs.formIntersection(foldable)
    }

    // MARK: Reading

    /// The rows the listener sees: every row except those under a folded chapter.
    public func visibleRows(in rows: [Row]) -> [Row] {
        guard !foldedChapterIDs.isEmpty else { return rows }
        var result: [Row] = []
        var hiding = false
        for row in rows {
            if row.isChapter {
                hiding = foldedChapterIDs.contains(row.id)
                result.append(row)
            } else if !hiding {
                result.append(row)
            }
        }
        return result
    }

    /// The folded chapter that hides this row, or nil when the row is visible (or isn't on the rail).
    public func foldedChapterHiding(_ rowID: String, in rows: [Row]) -> String? {
        var header: String?
        for row in rows {
            if row.isChapter { header = row.id }
            if row.id == rowID {
                guard !row.isChapter, let header, foldedChapterIDs.contains(header) else { return nil }
                return header
            }
        }
        return nil
    }

    /// Unfold the chapter that hides this row, so a row the listener asked to be taken to is on screen.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func reveal(_ rowID: String, in rows: [Row]) -> Bool {
        guard let header = foldedChapterHiding(rowID, in: rows) else { return false }
        foldedChapterIDs.remove(header)
        return true
    }

    /// The row to scroll to for a row that may be hidden: the row itself, or the folded chapter that hides it.
    public func visibleID(for rowID: String, in rows: [Row]) -> String {
        foldedChapterHiding(rowID, in: rows) ?? rowID
    }

    /// What a folded chapter row says about its hidden rows. Nil for a chapter that isn't folded.
    public func summary(forChapter chapterID: String, in rows: [Row], currentIDs: Set<String>) -> HiddenSummary? {
        guard foldedChapterIDs.contains(chapterID), let hidden = Self.members(in: rows)[chapterID] else { return nil }
        return HiddenSummary(
            hiddenCount: hidden.count,
            hasNew: hidden.contains { $0.isNew },
            containsCurrent: hidden.contains { currentIDs.contains($0.id) }
        )
    }
}
