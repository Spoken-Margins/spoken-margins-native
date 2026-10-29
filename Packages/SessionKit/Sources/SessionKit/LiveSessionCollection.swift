import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The phone's store of live sessions (#2487 slice 1a; DESIGN section 9, "The session store"): many sessions, each
/// found by its id, ended and saved ones included, plus the record of what the listener deleted. Plain files under
/// Application Support, read and written only on `LiveSessionFileWorker`:
///
/// - `LiveSession/Sessions/<id>.json`: one file per session, in the same JSON as `current.json`.
/// - `LiveSession/deletions.json`: deleted session spans and Margin ids.
/// - `LiveSession/current.json`: unchanged, and still written for the build before this one, which reads only it.
///   It holds the running named session, else the most recently ended one not yet saved, else nothing.
///
/// Nothing in the app's database changes. The build before this one never reads `Sessions/` or `deletions.json`.
public struct LiveSessionCollection {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var directory: URL {
        root.appending(path: "LiveSession", directoryHint: .isDirectory).appending(path: "Sessions", directoryHint: .isDirectory)
    }

    var deletionsURL: URL {
        root.appending(path: "LiveSession", directoryHint: .isDirectory).appending(path: "deletions.json")
    }

    /// A file name for any id: the id itself when it is plain, else a cleaned id with a hash so two ids never share one.
    static func fileName(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let clean = String(id.unicodeScalars.map { $0.isASCII && allowed.contains($0) ? Character($0) : "_" }.prefix(100))
        guard clean != id else { return id + ".json" }
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(clean)-\(hash).json"
    }

    func url(for id: String) -> URL {
        directory.appending(path: Self.fileName(for: id))
    }

    /// Every stored session. A file that doesn't read is left in place and skipped, never deleted.
    public func loadAll() -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decoder.decode(LiveSession.self, from: $0) }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    public func save(_ session: LiveSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(session).write(to: url(for: session.id), options: .atomic)
    }

    public func remove(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    public func loadDeletions() -> LiveSessionFiling.Deletions {
        guard let data = try? Data(contentsOf: deletionsURL),
              let deletions = try? Self.decoder.decode(LiveSessionFiling.Deletions.self, from: data) else { return .init() }
        return deletions
    }

    public func saveDeletions(_ deletions: LiveSessionFiling.Deletions) throws {
        try FileManager.default.createDirectory(at: deletionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(deletions).write(to: deletionsURL, options: .atomic)
    }

    /// Takes in `current.json` without loss: a session the store lacks is added, and Margins an earlier build added to
    /// one it has are merged in. Deleted sessions and Margins stay deleted. Returns true when the store changed.
    @discardableResult
    public func migrateLegacyCurrent() throws -> Bool {
        guard let legacy = LiveSessionStore.load(from: root) else { return false }
        let deletions = loadDeletions()
        guard !deletions.deletedSession(legacy.id) else { return false }
        let stored = loadAll().first { $0.id == legacy.id }
        guard var merged = stored else {
            var adopted = legacy
            adopted.margins.removeAll { deletions.marginIds.contains($0.id) }
            try save(adopted)
            return true
        }
        var changed = false
        for margin in legacy.margins where !deletions.marginIds.contains(margin.id) {
            if let index = merged.margins.firstIndex(where: { $0.id == margin.id }) {
                if let words = margin.spokenTranscript, merged.margins[index].spokenTranscript == nil {
                    changed = merged.setTranscript(words, forMarginId: margin.id) || changed
                }
            } else {
                merged.margins.append(margin)
                changed = true
            }
        }
        if merged.endedAt == nil, let end = legacy.endedAt {
            merged.endedAt = end
            merged.endTappedAt = legacy.endTappedAt
            merged.endPositionMs = merged.endPositionMs ?? legacy.endPositionMs
            merged.endWhere = merged.endWhere ?? legacy.endWhere
            merged.endPlace = merged.endPlace ?? legacy.endPlace
            changed = true
        }
        guard changed else { return false }
        merged.margins.sort { $0.markedAt < $1.markedAt }
        try save(merged)
        return true
    }

    /// The session `current.json` holds for the earlier build: the running named session, else the most recently
    /// ended named session not yet saved.
    public static func legacyMirror(of sessions: [LiveSession]) -> LiveSession? {
        let named = sessions.filter { $0.isQuick != true && $0.savedItemId == nil }
        if let running = named.filter({ $0.endedAt == nil }).max(by: { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }) { return running }
        return named.max(by: { ($0.endedAt ?? $0.startedAt, $0.id) < ($1.endedAt ?? $1.startedAt, $1.id) })
    }

    /// Writes `current.json` to match the store, or removes it.
    public func writeLegacyMirror(_ sessions: [LiveSession]) throws {
        if let mirror = Self.legacyMirror(of: sessions) {
            if LiveSessionStore.load(from: root) != mirror { try LiveSessionStore.save(mirror, in: root) }
        } else {
            LiveSessionStore.remove(from: root)
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601withFractions
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractions
        return decoder
    }
}
