import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// What the diagnostics export carries and what it leaves out (#968). This export is the one place a
/// tester sends data out of the app, so the redaction rules are the product: the app reads its state,
/// and this type decides which of it is allowed to leave the phone.
public enum DiagnosticsExport {
    public static let schemaVersion = "spoken-margins.diagnostics.v1"

    /// The values only the running app can read. They are set after everything else, so a live or stored
    /// entry with the same key never overrides them. Their values are not redacted by key, but the two event
    /// logs are scrubbed for item ids, session ids and record-time tokens (see `eventLog`).
    public struct Fixed: Equatable, Sendable {
        public var developerBuild: String
        /// `nil` leaves the key out of the export, even if a live or stored entry had one.
        public var developerRecording: String?
        /// `nil` leaves the key out of the export, even if a live or stored entry had one, and leaves out
        /// `responsiveness`, which is summed from these events.
        public var playbackEvents: String?
        public var exportedAt: Date
        public var playbackStatus: String
        public var sessionPhase: String
        public var targetType: String?
        public var pendingAIJobs: Int

        public init(
            developerBuild: String,
            developerRecording: String?,
            playbackEvents: String?,
            exportedAt: Date,
            playbackStatus: String,
            sessionPhase: String,
            targetType: String?,
            pendingAIJobs: Int
        ) {
            self.developerBuild = developerBuild
            self.developerRecording = developerRecording
            self.playbackEvents = playbackEvents
            self.exportedAt = exportedAt
            self.playbackStatus = playbackStatus
            self.sessionPhase = sessionPhase
            self.targetType = targetType
            self.pendingAIJobs = pendingAIJobs
        }
    }

    /// Live diagnostics under these exact names hold text the listener typed, pasted or chose, so they
    /// never leave the phone.
    public static func keyMayContainUserContent(_ key: String) -> Bool {
        [
            "lastStatus",
            "recentFailure",
            "quickAccessFolder",
            "lastSourceLinkClipboardPaste",
            "lastBrowserTextSource",
            "lastSharedPDFImport"
        ].contains(key)
    }

    /// Live diagnostics under these exact names hold a library item id. For a web import that id is the page
    /// title plus the start of its address (#2850), so the value leaves as a token.
    static let keysHoldingAnItemId: Set<String> = [
        "lastImport",
        "lastBrowserTextImport",
        "lastBackgroundBrowserTextImport",
        "lastBackgroundSourceLinkImport",
        "lastSourceLinkImport",
        "lastGeneratedMapItem"
    ]

    /// Short, non-reversible token for an id that may be a title or an address. Without a salt it is a plain
    /// hash, which the app uses at record time. At export every token is salted with a value made for that one
    /// export and never written to it (#3548), so a posted token can't be checked against a guessed title and
    /// two exports of one library share no tokens. Inside one export the same id gives the same token in a key
    /// and in a value, so entries about one item still line up.
    public static func token(_ id: String, salt: Data? = nil) -> String {
        var input = Data()
        if let salt { input.append(salt) }
        input.append(Data(id.utf8))
        return SHA256.hash(data: input).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh salt for one export.
    public static func newSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// `name:<id>` keys keep the name and carry the id as a token. Only the first colon splits, because the
    /// id itself may hold colons (a title, the `https:` of an address).
    static func exportedKey(_ key: String, salt: Data?) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        let suffix = key[key.index(after: colon)...]
        guard !suffix.isEmpty else { return key }
        // A per-Margin key is already `<hashed session token>/<Margin id>` (PodcastAnchorCaptureDiagnostics).
        if suffix.range(of: #"^[0-9a-f]{8}/[0-9A-Za-z-]+$"#, options: .regularExpression) != nil { return key }
        return "\(key[..<colon]):\(token(String(suffix), salt: salt))"
    }

    /// `none` and an empty value say no item; anything else under an item-id key is an id.
    static func exportedValue(forKey key: String, _ value: String, salt: Data?) -> String {
        if keysHoldingAnItemId.contains(key), !value.isEmpty, value != "none" { return token(value, salt: salt) }
        if key.hasPrefix("sourceEntryImport:"), value.hasPrefix("item:") {
            // `item:<id>,subscription:<id>`: the item id is the part that can carry a title.
            let rest = value.dropFirst("item:".count)
            let end = rest.range(of: ",subscription:")?.lowerBound ?? rest.endIndex
            return "item:\(token(String(rest[..<end]), salt: salt))\(rest[end...])"
        }
        return value
    }

    /// A library item id, or a session id built from one. A web import's id starts with the page title and an
    /// Obsidian id with the file name, so the shape is what gives them away, wherever in the export they sit
    /// (#3548). Values from outside the key lists can't be told apart by their key, so the scrubber reads the value.
    private static let itemIdPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:(?<![A-Za-z0-9])|(?<=\\[nrt]))(?:session-)?item-[\p{L}\p{N}_-]+"#
    )

    /// What ends a path's last name besides a file extension: a line end, a quote, a bracket or punctuation.
    private static let pathBreak = #"\n"'\x{2018}\x{2019}\x{201C}\x{201D}<>|;:,)\]\}"#
    /// `/Users/…`, `/private/…`, `/var/…`, `/tmp/…`, `/Volumes/…`, `/Library/…`, `/Applications/…` and `/home/…`. A name may hold spaces (iCloud Drive's
    /// "Mobile Documents", "Application Support", a folder the listener named). The path runs over a space when
    /// the next word has a slash in it, and ends with a last name, up to six words, that has a file extension (#3548). A
    /// folder with a space as the very last name, and no extension, loses its last word to the sentence.
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9._~%-])/(?:private|Users|var|tmp|Volumes|Library|Applications|home)/[^\s\#(pathBreak)]*(?: +[^\s\#(pathBreak)]*/[^\s\#(pathBreak)]*)*(?:(?: +[^\s\#(pathBreak)/]+){0,5} +[^\s\#(pathBreak)/]*\.[A-Za-z0-9]{1,6}(?![^\s\#(pathBreak)]))?"#
    )
    /// A file name in quotes, as system errors write it: `The file "Family Taxes 2025.pdf" couldn't be opened.`
    private static let quotedFileNamePattern = try! NSRegularExpression(
        pattern: #"([\x{201C}"])[^\x{201D}"\n]{1,200}\.[A-Za-z0-9]{1,6}([\x{201D}"])"#
    )
    /// A 12 or 16 hex-digit token made at record time (an unsalted hash of an id, of toast text or of an error).
    private static let recordTokenPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?<!<id:)[0-9a-f]{12}(?:[0-9a-f]{4})?(?![A-Za-z0-9])"#
    )

    /// Web addresses, file paths, quoted file names and item ids become placeholders, wherever they sit in a
    /// value. Item ids leave as a token, so entries about one item still line up.
    public static func redactedValue(_ value: String, salt: Data? = nil) -> String {
        var text = value.replacingOccurrences(of: #"https?://[^\s]+"#, with: "<redacted-url>", options: .regularExpression)
        text = replace(pathPattern, in: text) { _ in "<redacted-path>" }
        text = replace(quotedFileNamePattern, in: text) { match in "\(match[1])<redacted-file>\(match[2])" }
        return itemIdsAsTokens(text, salt: salt)
    }

    /// Item ids and session ids in text, as `<id:token>`. The token form holds no `item-`, so a second pass
    /// leaves it alone. JSON text stays valid: an id holds no quote, backslash or control character.
    static func itemIdsAsTokens(_ text: String, salt: Data?) -> String {
        replace(itemIdPattern, in: text) { match in "<id:\(token(match[0], salt: salt))>" }
    }

    /// A record-time token is hashed again with this export's salt, so an event log written before the salt
    /// existed can't be checked against a guessed title either (#3548). An all-digit run is a number, not a token.
    static func resaltedRecordTokens(_ text: String, salt: Data) -> String {
        replace(recordTokenPattern, in: text) { match in
            match[0].contains(where: { $0.isLetter }) ? token(match[0], salt: salt) : match[0]
        }
    }

    /// An event log is JSON the app wrote earlier, so it can't be redacted by key. Item ids and session ids in it
    /// become tokens and record-time tokens are salted. The responsiveness line is read off the original.
    static func eventLog(_ json: String, salt: Data) -> String {
        resaltedRecordTokens(itemIdsAsTokens(json, salt: salt), salt: salt)
    }

    /// Replaces each match; `match[0]` is the whole match, the rest are its capture groups.
    private static func replace(_ regex: NSRegularExpression, in text: String, with make: ([String]) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for found in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: found.range.location - cursor))
            let groups = (0..<found.numberOfRanges).map { index -> String in
                let range = found.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += make(groups)
            cursor = found.range.location + found.range.length
        }
        return out + ns.substring(from: cursor)
    }

    /// The export's entries: the live ones without user-content keys, with item ids in keys and values
    /// replaced by tokens (#2850), then the stored Margin entries (a stored entry wins a key clash), both
    /// redacted, then the fixed keys.
    public static func entries(
        live: [String: String],
        stored: [String: String],
        fixed: Fixed,
        salt: Data = newSalt()
    ) -> [String: String] {
        var safe: [String: String] = [:]
        for (key, value) in live where !keyMayContainUserContent(key) {
            safe[itemIdsAsTokens(exportedKey(key, salt: salt), salt: salt)] = redactedValue(exportedValue(forKey: key, value, salt: salt), salt: salt)
        }
        safe.merge(
            Dictionary(stored.map { (itemIdsAsTokens($0.key, salt: salt), redactedValue($0.value, salt: salt)) }) { _, last in last }
        ) { _, stored in stored }
        safe["developerBuild"] = fixed.developerBuild
        safe["developerRecording"] = fixed.developerRecording.map { eventLog($0, salt: salt) }
        safe["playbackEvents"] = fixed.playbackEvents.map { eventLog($0, salt: salt) }
        // Read off the events above, so a live or stored entry can't stand in for it (#2096).
        safe["responsiveness"] = fixed.playbackEvents.map { ResponsivenessSummary(playbackEventsJSON: $0).text }
        safe["schemaVersion"] = schemaVersion
        safe["exportedAt"] = ISO8601DateFormatter().string(from: fixed.exportedAt)
        safe["playbackStatus"] = fixed.playbackStatus
        safe["sessionPhase"] = fixed.sessionPhase
        safe["targetType"] = fixed.targetType ?? "none"
        safe["pendingAIJobs"] = "\(fixed.pendingAIJobs)"
        return safe
    }

    /// The text of the export file: pretty-printed JSON with the keys in order.
    public static func jsonText(_ entries: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
