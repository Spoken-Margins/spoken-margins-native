import Foundation
import SessionKit

/// #4858: the words of the import preview (`OPMLImportScreen`), kept here so they are host-tested. A row leads
/// with the show's name; a nameless row shows a readable address, never its whole feed URL; a home-network row
/// says so; named unusable lines are listed by name; and a Shortcut list that came in without names says how to
/// fix the Shortcut's Text step.
public enum OPMLImportPreviewWords {
    /// Where the previewed feeds came from.
    public enum Source: Equatable, Sendable {
        /// An OPML file from another app.
        case file
        /// The "Follow Podcasts in Spoken Margins" Shortcut action (#4284, #4290).
        case shortcut
        /// The shows the listener's own AI suggested (#4683).
        case assistant

        var isLinkList: Bool { self != .file }
    }

    /// One row of the preview, or of the lists after it (Already followed, Repeated, Followed).
    public struct Row: Equatable, Sendable {
        public var title: String
        /// The small line under the title; nil for none.
        public var detail: String?
        /// What VoiceOver reads: "name, host" or "No name, address".
        public var accessibilityLabel: String
        public var hasName: Bool
        public var isHomeNetwork: Bool
    }

    public static let homeNetworkDetail = "Home network address. Probably won't work away from home."

    /// A new feed's row in the preview.
    public static func row(_ candidate: SourceCandidate, source: Source) -> Row {
        let feedURL = candidate.feed?.url ?? ""
        let name = FeedDisplayName(title: candidate.title, feedURL: feedURL)
        let host = URLComponents(string: feedURL)?.host?.lowercased()
        let isHome = FeedHostClass.isHomeNetwork(url: feedURL)
        let detail: String?
        if isHome {
            detail = homeNetworkDetail
        } else if !name.hasName {
            detail = source.isLinkList ? "No name passed in" : "No name in the file"
        } else {
            detail = host.flatMap { $0.isEmpty ? nil : $0 }
        }
        var label = name.hasName ? [name.text] : ["No name", name.text]
        if name.hasName, let host, !host.isEmpty, host != name.text { label.append(host) }
        if isHome { label.append("home network address") }
        return Row(title: name.text, detail: detail, accessibilityLabel: label.joined(separator: ", "),
                   hasName: name.hasName, isHomeNetwork: isHome)
    }

    /// The title a feed shows in the lists that carry no small line (Already followed, Repeated in the file,
    /// Followed, Stopped before, Couldn't follow): the same title its preview row had.
    public static func title(_ title: String, feedURL: String?) -> String {
        FeedDisplayName(title: title, feedURL: feedURL ?? "").text
    }

    /// The line inside an empty New section; nil when the section has rows.
    public static func emptyNewLine(_ preview: OPMLImportPreview, source: Source) -> String? {
        guard preview.toFollow.isEmpty else { return nil }
        let everyEntryUnusable = preview.unusableOutlineCount > 0 && preview.alreadyFollowed.isEmpty && preview.duplicatesInFile.isEmpty
        if source == .shortcut, everyEntryUnusable {
            return "None of these lines had a feed link. In Shortcuts, check the Text step: the show's Name, a space, then its Feed URL."
        }
        return source.isLinkList ? "Nothing new to follow in this list." : "Nothing new to follow in this file."
    }

    /// The New section's footer: for a Shortcut list with at least one nameless row, how to get names. Never
    /// for a file or the AI's list, whose fix is not a Shortcut step.
    public static func newFooter(_ preview: OPMLImportPreview, source: Source) -> String? {
        guard source == .shortcut else { return nil }
        let nameless = preview.toFollow.filter { !FeedDisplayName(title: $0.title, feedURL: $0.feed?.url ?? "").hasName }.count
        guard nameless > 0 else { return nil }
        let came = nameless == 1 ? "1 show came in without a name, so it shows its web address." : "\(nameless) shows came in without a name, so they show their web address."
        return "\(came) In Shortcuts, make the Text step the show's Name, a space, then its Feed URL."
    }

    /// The section for lines with no usable feed link; nil when there are none.
    public struct UnusableSection: Equatable, Sendable {
        public var header: String
        /// The names to list, at most `OPMLImportPreview.unusableNameLimit`.
        public var names: [String]
        /// "and 4 more" under the names, when more lines are left than were listed; nil otherwise.
        public var more: String?
        /// The sentence for the section: a footer under listed names, or the section's only line without them.
        public var note: String
    }

    public static func unusableSection(_ preview: OPMLImportPreview, source: Source) -> UnusableSection? {
        let count = preview.unusableOutlineCount
        guard count > 0 else { return nil }
        let (names, _) = preview.unusableNameList()
        let left = count - names.count
        let more = names.isEmpty || left <= 0 ? nil : "and \(left) more"
        let skipped = "\(count) \(count == 1 ? "entry has" : "entries have") no feed link Spoken Margins can use, so \(count == 1 ? "it's" : "they're") skipped."
        if names.isEmpty {
            return UnusableSection(header: source == .shortcut ? "Can't follow (\(count))" : "Unusable (\(count))", names: [], more: nil, note: skipped)
        }
        let note = source == .shortcut
            ? "These have no public feed link. Shows that exist only in Apple Podcasts are like this."
            : "These have no feed link Spoken Margins can use, so they're skipped."
        return UnusableSection(header: source == .shortcut ? "Can't follow (\(count))" : "Unusable (\(count))", names: names, more: more, note: note)
    }
}
