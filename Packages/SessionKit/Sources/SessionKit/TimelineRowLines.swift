import Foundation

/// What kind of card a Timeline row is drawn as (#4778). Chapters and the Beginning are compact headers, a page's links,
/// pictures, embeds and tables are compact children, and every row that carries content (passages, footnotes, scenes,
/// Margins, replies, turns) keeps its full card. The app maps each `TimelineRailEntry.Action` case to one of these with a
/// switch that names every case, so a new kind of row has to choose.
public enum TimelineRowRole: Equatable, Sendable {
    case chapter
    case beginning
    case sourceElement(kind: SourceElement.Kind, linkHost: String?)
    case full
}

/// The words, icons and VoiceOver strings of a compact Timeline row and its fold control (#4778), so the view only lays
/// them out. The Design's rules: a chapter shows its type once (an icon, and "Chapter:" to VoiceOver) and its place once
/// (the corner); a folded chapter's hidden count lives on the fold control, never as a line of its own; a link folds its
/// host into its kind line.
public struct TimelineRowLines: Equatable, Sendable {
    /// False only for `full` rows, which keep today's card.
    public let isCompact: Bool
    /// The symbol before a header's title: `list.bullet` for a chapter, `backward.end` for the Beginning.
    public let leadingSystemImage: String?
    /// A child row's first line: "Link · x.com", "Link", "Picture", "Embed" or "Table".
    public let kindLine: String?
    public let kindSystemImage: String?
    /// A chapter is a heading, so VoiceOver's headings rotor jumps between chapters.
    public let isHeader: Bool

    public init(role: TimelineRowRole) {
        switch role {
        case .chapter:
            isCompact = true
            leadingSystemImage = "list.bullet"
            kindLine = nil
            kindSystemImage = nil
            isHeader = true
        case .beginning:
            isCompact = true
            leadingSystemImage = "backward.end"
            kindLine = nil
            kindSystemImage = nil
            isHeader = false
        case .sourceElement(let kind, let linkHost):
            isCompact = true
            leadingSystemImage = nil
            kindLine = Self.kindLine(kind: kind, linkHost: linkHost)
            kindSystemImage = Self.kindSystemImage(kind)
            isHeader = false
        case .full:
            isCompact = false
            leadingSystemImage = nil
            kindLine = nil
            kindSystemImage = nil
            isHeader = false
        }
    }

    /// The one name of each kind of page element, shared by the row, its sheet's title and VoiceOver.
    public static func kindName(_ kind: SourceElement.Kind) -> String {
        switch kind {
        case .link: "Link"
        case .picture: "Picture"
        case .embed: "Embed"
        case .table: "Table"
        }
    }

    public static func kindSystemImage(_ kind: SourceElement.Kind) -> String {
        switch kind {
        case .link: "link"
        case .picture: "photo"
        case .embed: "play.rectangle"
        case .table: "tablecells"
        }
    }

    static func kindLine(kind: SourceElement.Kind, linkHost: String?) -> String {
        if kind == .link, let linkHost, !linkHost.isEmpty { return "Link · \(linkHost)" }
        return kindName(kind)
    }

    /// The title a row shows: a chapter with no title says "Untitled chapter" rather than nothing.
    public static func displayTitle(role: TimelineRowRole, title: String) -> String {
        if role == .chapter, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Untitled chapter" }
        return title
    }

    /// What VoiceOver reads for a compact row, or nil for a `full` row, which keeps today's label.
    /// - Parameters:
    ///   - spokenPosition: the corner as VoiceOver reads it ("48 percent", "about 65 percent", "1 hour, 7 minutes, 30 seconds").
    ///   - currentSpoken: the current line with its separators read as pauses ("Current chapter, 51%"); nil when the row
    ///     isn't current.
    ///   - containsCurrent: the chapter is folded and the playhead is on one of its hidden rows.
    ///   - detail: the Beginning's overview excerpt, read after its place; ignored for every other role.
    public static func spokenLabel(role: TimelineRowRole, title: String, spokenPosition: String, currentSpoken: String?,
                                   containsCurrent: Bool, detail: String = "") -> String? {
        let shownTitle = displayTitle(role: role, title: title)
        switch role {
        case .full:
            return nil
        case .chapter:
            if let currentSpoken {
                return "\(currentSpoken). \(shownTitle). Starts at \(spokenPosition)."
            }
            let base = "Chapter: \(shownTitle), \(spokenPosition)."
            return containsCurrent ? "\(base) Playing in this chapter." : base
        case .beginning:
            var parts: [String] = []
            if let currentSpoken { parts.append("\(currentSpoken).") }
            parts.append("Beginning, \(spokenPosition).")
            if !detail.isEmpty { parts.append(detail) }
            return parts.joined(separator: " ")
        case .sourceElement(let kind, let linkHost):
            let lead: String
            if kind == .link, let linkHost, !linkHost.isEmpty {
                lead = "Link to \(linkHost)"
            } else {
                lead = kindName(kind)
            }
            let base = "\(lead): \(shownTitle), \(spokenPosition)."
            return currentSpoken.map { "\($0). \(base)" } ?? base
        }
    }

    /// The fold control's VoiceOver label: short, so the chapter's title isn't read twice in a row.
    public static func foldLabel(isFolded: Bool) -> String {
        isFolded ? "Expand" : "Collapse"
    }

    /// The fold control's VoiceOver value: "3 rows hidden", "3 rows hidden, new inside", or "Expanded".
    public static func foldValue(summary: TimelineChapterFolding.HiddenSummary?) -> String {
        summary?.text ?? "Expanded"
    }

    /// What Voice Control accepts for the fold control: "Expand", "Expand chapter", "Expand <title>".
    public static func foldInputLabels(isFolded: Bool, title: String) -> [String] {
        let verb = foldLabel(isFolded: isFolded)
        let shownTitle = displayTitle(role: .chapter, title: title)
        return [verb, "\(verb) chapter", "\(verb) \(shownTitle)"]
    }

    /// The chapter row's own named action, so VoiceOver can fold or open it without finding the control.
    public static func rowFoldActionName(isFolded: Bool) -> String {
        isFolded ? "Expand chapter" : "Collapse chapter"
    }
}
