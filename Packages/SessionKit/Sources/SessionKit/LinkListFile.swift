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
///
/// An entry may carry `"follow": true` (#4683): the link is a show the listener's assistant suggests following, not an
/// item to add. Only the JSON value `true` counts; `"true"`, `1` and a missing field are not a follow. Consumers split
/// the entries by `Entry.follow`.
public struct LinkListFile: Equatable, Sendable {
    public static let schemaVersion = "spoken-margins.link-list.v1"
    /// Every version of this format starts with this. A different version under it is a newer (or mistyped) link list.
    public static let schemaFamilyPrefix = "spoken-margins.link-list."
    /// One file holds at most this many entries; more is refused as a whole, so a long list never half arrives.
    public static let maxEntries = 50
    /// A link file bigger than this is refused before it is read into memory.
    public static let maxFileBytes = 1_000_000
    /// One list suggests at most this many shows to follow; more is refused as a whole (#4683).
    public static let maxFollows = 10

    /// What the listener reads when a file or pasted reply is over `maxFileBytes`.
    public static var tooLargeMessage: String {
        "This link list is larger than \(maxFileBytes / 1_000_000) MB. Split it into smaller files."
    }

    public struct Entry: Equatable, Sendable {
        /// The link, trimmed. Always `https` with a host.
        public var url: String
        public var title: String?
        /// True only when the file said `"follow": true`: a show to suggest following, not an item to add.
        public var follow: Bool

        public init(url: String, title: String? = nil, follow: Bool = false) {
            self.url = url
            self.title = title
            self.follow = follow
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
                : .rejected(tooLargeMessage)
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
        // The follow flags come from a second, strict read of the same bytes. If it doesn't line up with the first
        // (the same key twice, say), refuse the list instead of quietly treating every follow as an item.
        guard let follows = followFlags(in: data), follows.count == rawEntries.count,
              zip(follows, rawEntries).allSatisfy({ $0.url == ($1 as? [String: Any])?["url"] as? String }) else {
            return .rejected(unreadableMessage)
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
            entries.append(Entry(url: rawURL, title: cleanTitle(fields?["title"]), follow: follows[index].follow))
        }
        guard !entries.isEmpty else {
            return .rejected("This link list has no https links, so nothing was added. Every \"url\" must start with https://.")
        }
        guard entries.lazy.filter(\.follow).count <= maxFollows else {
            return .rejected("This list suggests more than \(maxFollows) shows to follow. Ask for \(maxFollows) or fewer.")
        }
        return .linkList(LinkListFile(title: cleanTitle(object["title"]), entries: entries, skipped: skipped))
    }

    /// Whether each raw entry said `"follow": true`, by position. Read with `JSONDecoder`, which tells the JSON
    /// boolean `true` from the number `1` and the string `"true"` the same way on every platform;
    /// `JSONSerialization` bridges them differently on Linux and Apple platforms.
    private static func followFlags(in data: Data) -> [(url: String?, follow: Bool)]? {
        struct Flags: Decodable {
            let entries: [Flag]
        }
        struct Flag: Decodable {
            enum Keys: String, CodingKey { case url, follow }
            let url: String?
            let follow: Bool
            init(from decoder: Decoder) throws {
                let container = try? decoder.container(keyedBy: Keys.self)
                url = (try? container?.decode(String.self, forKey: .url)) ?? nil
                follow = (try? container?.decode(Bool.self, forKey: .follow)) ?? false
            }
        }
        return (try? JSONDecoder().decode(Flags.self, from: data))?.entries.map { ($0.url, $0.follow) }
    }

    static let unreadableMessage = "This link list couldn't be read. Check that it is valid JSON with one \"entries\" list."

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
