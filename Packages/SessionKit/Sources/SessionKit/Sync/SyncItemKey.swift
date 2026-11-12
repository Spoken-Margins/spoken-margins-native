#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The key two phones give the same article, episode or note, so each makes the same sync record for it (#4152). Local
/// item ids are made on the device and differ between phones; this does not.
///
/// In order: a Spoken Note's id; a podcast episode's feed GUID with its show; the canonical source address; the digest
/// of the normalized text. A key says "same" only on a match of the first of these an item has. Two items that merely
/// look alike get different keys, which is the safe way to be wrong: a Margin is never attached to other text.
///
/// Keys other than a note's are hashes, so a record name shows Apple nothing about what the listener reads.
public enum SyncItemKey {
    public static let noteKeyPrefix = "spoken-note-"
    static let version = "v1"

    /// The key for an item, or nil when it has nothing to match by (no address, no text digest): such an item stays on its phone.
    public static func derive(
        noteId: String? = nil,
        episodeGUID: String? = nil,
        showTitle: String? = nil,
        sourceURL: String? = nil,
        normalizedContentSHA256: String? = nil
    ) -> String? {
        if let noteId, !noteId.isEmpty { return noteKeyPrefix + noteId }
        if let guid = trimmed(episodeGUID), let show = normalizedShow(showTitle) {
            return "ep-" + hash("ep|\(show)|\(guid)")
        }
        if let canonical = canonicalSourceKey(sourceURL) { return "src-" + hash("src|\(canonical)") }
        if let digest = trimmed(normalizedContentSHA256)?.lowercased() { return "txt-" + hash("txt|\(digest)") }
        return nil
    }

    /// The key for a Library item. `digests` is what the store keeps beside the item (`ItemTextDigests`).
    public static func derive(item: Item, digests: ItemTextDigests?) -> String? {
        derive(
            noteId: SpokenNoteItem.noteId(of: item),
            episodeGUID: item.episodeGUID,
            showTitle: item.showTitle,
            sourceURL: item.sourceURL ?? httpReference(item.externalReference),
            normalizedContentSHA256: digests?.normalizedContentSHA256
        )
    }

    /// An address as a stable string, or nil when it is not a web address. Scheme and host are lowercased; the
    /// fragment, a default port, a trailing slash and tracking parameters are dropped; `http` counts as `https`; the rest
    /// of the query is sorted.
    /// Nothing else is folded: `www.` and a different path are different sources.
    public static func canonicalSourceKey(_ address: String?) -> String? {
        guard let address = trimmed(address), var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = scheme == "http" ? "https" : scheme
        components.host = host
        components.fragment = nil
        components.user = nil
        components.password = nil
        if let port = components.port, port == 80 || port == 443 { components.port = nil }
        if components.path.count > 1, components.path.hasSuffix("/") { components.path.removeLast() }
        if components.path.isEmpty { components.path = "/" }
        let kept = (components.queryItems ?? [])
            .filter { !isTracking($0.name) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string
    }

    private static func isTracking(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("utm_") || ["fbclid", "gclid", "mc_cid", "mc_eid", "igshid"].contains(lowered)
    }

    private static func httpReference(_ reference: String?) -> String? {
        guard let reference = trimmed(reference), reference.lowercased().hasPrefix("http") else { return nil }
        return reference
    }

    private static func normalizedShow(_ title: String?) -> String? {
        guard let title else { return nil }
        let folded = title.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func hash(_ input: String) -> String {
        SHA256.hash(data: Data("\(version)|\(input)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
