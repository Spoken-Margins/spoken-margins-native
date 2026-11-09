import Foundation

/// A structured list of links a listener (or their own assistant) saves as one JSON file (#3767). Each entry is added
/// as if the link had been pasted or shared, in file order.
///
/// A file is a link list only because its JSON says so: an object whose `schemaVersion` is
/// `spoken-margins.link-list.v1`. A `.txt`, `.md` or `.markdown` file is never read here, whatever it holds, and JSON
/// with any other `schemaVersion` (a Listening Edition, for one) is `.notALinkList`, so it goes the way it always did.
///
/// ```json
/// {
///   "schemaVersion": "spoken-margins.link-list.v1",
///   "title": "Morning brief, November 8",
///   "entries": [
///     { "url": "https://example.com/article", "title": "Optional display title" },
///     { "url": "https://example.com/episode" }
///   ]
/// }
/// ```
///
/// `schemaVersion` and at least one entry with an `https` `url` are required; `title` is optional on the list and on
/// each entry. Unknown fields are ignored, so a later version can add them. One link is a list with one entry.
public struct LinkListFile: Equatable, Sendable {
    public static let schemaVersion = "spoken-margins.link-list.v1"
    /// Every version of this format starts with this. A different version under it is a newer (or mistyped) link list.
    public static let schemaFamilyPrefix = "spoken-margins.link-list."
    /// One file holds at most this many entries; more is refused as a whole, so a long list never half arrives.
    public static let maxEntries = 50
    /// A link file bigger than this is refused before it is read into memory.
    public static let maxFileBytes = 1_000_000

    public struct Entry: Equatable, Sendable {
        /// The link, trimmed. Always `https` with a host.
        public var url: String
        public var title: String?

        public init(url: String, title: String? = nil) {
            self.url = url
            self.title = title
        }
    }

    /// An entry the file listed but the app will not add, and why (shown to the listener).
    public struct SkippedEntry: Equatable, Sendable {
        /// Position in the file's `entries`, from 1.
        public var position: Int
        /// What the entry said, trimmed and cut short, or nil when it had no `url` text.
        public var text: String?
        public var reason: String

        public init(position: Int, text: String?, reason: String) {
            self.position = position
            self.text = text
            self.reason = reason
        }
    }

    public var title: String?
    /// The links to add, in playing order. A link listed twice is here once, at its first place.
    public var entries: [Entry]
    public var skipped: [SkippedEntry]

    public init(title: String? = nil, entries: [Entry], skipped: [SkippedEntry] = []) {
        self.title = title
        self.entries = entries
        self.skipped = skipped
    }

    public enum Recognition: Equatable, Sendable {
        /// Not this format: not a JSON object, no `schemaVersion` text, or another format's `schemaVersion`.
        case notALinkList
        case linkList(LinkListFile)
        /// It says it is a link list, but this build can't take it. The message is for the listener.
        case rejected(String)
    }

    /// Decides what `data` is. It never throws and never looks at file names or at URLs in the content.
    public static func recognize(_ data: Data) -> Recognition {
        guard data.count <= maxFileBytes else {
            // Too large to be worth parsing; only say so if it announces itself near the top.
            return data.prefix(512).range(of: Data(schemaFamilyPrefix.utf8)) == nil
                ? .notALinkList
                : .rejected("This link list is larger than \(maxFileBytes / 1_000_000) MB. Split it into smaller files.")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["schemaVersion"] as? String else { return .notALinkList }
        guard version.hasPrefix(schemaFamilyPrefix) else { return .notALinkList }
        guard version == schemaVersion else {
            return .rejected("This link list is version \"\(version)\", which this app can't read. Update Spoken Margins, or ask your assistant for a \"\(schemaVersion)\" list.")
        }
        guard let rawEntries = object["entries"] as? [Any], !rawEntries.isEmpty else {
            return .rejected("This link list has no entries. Add at least one with an https \"url\".")
        }
        guard rawEntries.count <= maxEntries else {
            return .rejected("This link list has \(rawEntries.count) links; one file may hold at most \(maxEntries). Split it into smaller files.")
        }
        var entries: [Entry] = []
        var skipped: [SkippedEntry] = []
        var seen = Set<String>()
        for (index, raw) in rawEntries.enumerated() {
            let position = index + 1
            let fields = raw as? [String: Any]
            let rawURL = (fields?["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawURL, !rawURL.isEmpty else {
                skipped.append(SkippedEntry(position: position, text: nil, reason: "has no \"url\""))
                continue
            }
            guard isHTTPSLink(rawURL) else {
                skipped.append(SkippedEntry(position: position, text: shortened(rawURL), reason: "is not an https link"))
                continue
            }
            guard seen.insert(rawURL).inserted else { continue }
            entries.append(Entry(url: rawURL, title: cleanTitle(fields?["title"])))
        }
        guard !entries.isEmpty else {
            return .rejected("This link list has no https links, so nothing was added. Every \"url\" must start with https://.")
        }
        return .linkList(LinkListFile(title: cleanTitle(object["title"]), entries: entries, skipped: skipped))
    }

    /// One line for the listener about what a list did not bring in, or nil when it all came in.
    public static func skippedNote(_ skipped: [SkippedEntry]) -> String? {
        guard !skipped.isEmpty else { return nil }
        let parts = skipped.prefix(3).map { entry -> String in
            guard let text = entry.text else { return "Entry \(entry.position) \(entry.reason)" }
            return "\(text) \(entry.reason)"
        }
        let more = skipped.count > 3 ? " and \(skipped.count - 3) more" : ""
        return "Skipped: " + parts.joined(separator: "; ") + more + "."
    }

    private static func isHTTPSLink(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    private static func cleanTitle(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func shortened(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(57)) + "..." : text
    }
}
