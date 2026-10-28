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
    /// entry with the same key never overrides them, and they are not redacted.
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

    /// Short, stable, non-reversible token for an id that may be a title or an address. The same id gives the
    /// same token in a key and in a value, so entries about one item still line up.
    public static func token(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// `name:<id>` keys keep the name and carry the id as a token. Only the first colon splits, because the
    /// id itself may hold colons (a title, the `https:` of an address).
    static func exportedKey(_ key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        let suffix = key[key.index(after: colon)...]
        guard !suffix.isEmpty else { return key }
        // A per-Margin key is already `<hashed session token>/<Margin id>` (PodcastAnchorCaptureDiagnostics).
        if suffix.range(of: #"^[0-9a-f]{8}/[0-9A-Za-z-]+$"#, options: .regularExpression) != nil { return key }
        return "\(key[..<colon]):\(token(String(suffix)))"
    }

    /// `none` and an empty value say no item; anything else under an item-id key is an id.
    static func exportedValue(forKey key: String, _ value: String) -> String {
        if keysHoldingAnItemId.contains(key), !value.isEmpty, value != "none" { return token(value) }
        if key.hasPrefix("sourceEntryImport:"), value.hasPrefix("item:") {
            // `item:<id>,subscription:<id>`: the item id is the part that can carry a title.
            let rest = value.dropFirst("item:".count)
            let end = rest.range(of: ",subscription:")?.lowerBound ?? rest.endIndex
            return "item:\(token(String(rest[..<end])))\(rest[end...])"
        }
        return value
    }

    /// Web addresses and file paths (`/private`, `/Users`, `/var`) become placeholders, up to the next
    /// whitespace, wherever they sit in a value.
    public static func redactedValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: "<redacted-url>", options: .regularExpression)
            .replacingOccurrences(of: #"/(?:private|Users|var)/[^\s]+"#, with: "<redacted-path>", options: .regularExpression)
    }

    /// The export's entries: the live ones without user-content keys, with item ids in keys and values
    /// replaced by tokens (#2850), then the stored Margin entries (a stored entry wins a key clash), both
    /// redacted, then the fixed keys.
    public static func entries(live: [String: String], stored: [String: String], fixed: Fixed) -> [String: String] {
        var safe: [String: String] = [:]
        for (key, value) in live where !keyMayContainUserContent(key) {
            safe[exportedKey(key)] = redactedValue(exportedValue(forKey: key, value))
        }
        safe.merge(stored.mapValues(redactedValue)) { _, stored in stored }
        safe["developerBuild"] = fixed.developerBuild
        safe["developerRecording"] = fixed.developerRecording
        safe["playbackEvents"] = fixed.playbackEvents
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
