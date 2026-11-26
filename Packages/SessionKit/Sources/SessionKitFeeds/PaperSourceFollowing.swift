import Foundation
import SessionKit

// #4341: following, refreshing, opening and unfollowing a reading list, over a store and a fetcher, so the whole
// flow runs on Linux. The app's `PaperSourcesState` only calls these and publishes the records.

public struct PaperSourceFollowing: Sendable {
    /// A list is read again when Following opens or is pulled, at most this often unless pulled.
    public static let refreshInterval: TimeInterval = 30 * 60

    public enum FollowOutcome: Equatable, Sendable {
        case followed(PaperSourceRecord)
        /// The same list was already followed; nothing changed.
        case alreadyFollowing(PaperSourceRecord)
        /// The line to show under the field; the field keeps what was pasted.
        case rejected(String)
        /// Not a paper link: the existing feed follow takes it, exactly as before.
        case notAPaperLink
    }

    let store: PaperSourceStoring
    let fetcher: PaperSourceFetcher

    public init(store: PaperSourceStoring, fetcher: PaperSourceFetcher) {
        self.store = store
        self.fetcher = fetcher
    }

    /// What Follow on the Follow papers screen does with the pasted text. A PubMed RSS link is followed as papers
    /// (#5201); a search someone followed as a feed before that stays a feed subscription, untouched.
    public func follow(pasted: String, apiKey: String?, zoteroConnected: Bool, now: Date) async -> FollowOutcome {
        switch PaperFeedLink.recognize(pasted) {
        case .notAPaperLink:
            return .notAPaperLink
        case .rejected(let problem):
            return .rejected(problem.message(zoteroConnected: zoteroConnected))
        case .source(let source):
            return await follow(source: source, link: pasted.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey,
                                zoteroConnected: zoteroConnected, now: now)
        }
    }

    /// Follows a list: it is read first, so a private, missing or unreachable list is never stored.
    public func follow(source: PaperSource, link: String, apiKey: String?, zoteroConnected: Bool, now: Date) async -> FollowOutcome {
        if let existing = (try? store.loadPaperSources())?.first(where: { $0.id == source.identifier }) {
            return .alreadyFollowing(existing)
        }
        let snapshot: PaperSourceSnapshot
        do {
            snapshot = try await fetcher.fetch(source, apiKey: apiKey)
        } catch {
            return .rejected(error.message(zoteroConnected: zoteroConnected, provider: source.provider))
        }
        var record = PaperSourceRecord(source: source, link: link, title: snapshot.title ?? Self.fallbackTitle(source), followedAt: now)
        record.apply(title: snapshot.title, entries: snapshot.entries, totalCount: snapshot.totalCount, at: now)
        do { try store.savePaperSource(record) } catch { return .rejected("Couldn't save that. Try again.") }
        return .followed(record)
    }

    /// Reads a followed list again and stores what came back. On a failure the stored list stays as it was.
    public func refresh(_ record: PaperSourceRecord, apiKey: String?, now: Date) async -> Result<PaperSourceRecord, PaperFetchProblem> {
        let snapshot: PaperSourceSnapshot
        do {
            snapshot = try await fetcher.fetch(record.source, apiKey: apiKey)
        } catch {
            return .failure(error)
        }
        // Applied to the stored copy in one step: the listener may have opened it, set it Quiet or unfollowed it
        // meanwhile, and none of that is undone (an unfollowed list stays unfollowed).
        do {
            let current = try store.updatePaperSource(id: record.id) {
                $0.apply(title: snapshot.title, entries: snapshot.entries, totalCount: snapshot.totalCount, at: now)
            }
            return .success(current ?? record)
        } catch {
            return .failure(.unreachable)
        }
    }

    /// The lists due a refresh: never read, or read longer ago than `refreshInterval`; every list when pulled. A list of
    /// the listener's own library waits while no key, or another user's key, is connected.
    public static func due(_ records: [PaperSourceRecord], connectedUserID: Int?, now: Date, pulled: Bool) -> [PaperSourceRecord] {
        records.filter { record in
            if !record.source.isReadable(connectedUserID: connectedUserID) { return false }
            if pulled { return true }
            guard let last = record.lastRefreshedAt else { return true }
            return now.timeIntervalSince(last) >= refreshInterval || now < last
        }
    }

    /// Opening the list's screen: from now on its row counts papers joined after this.
    @discardableResult
    public func markOpened(id: String, now: Date) throws -> PaperSourceRecord? {
        try store.updatePaperSource(id: id) { $0.lastOpenedAt = now }
    }

    @discardableResult
    public func setQuiet(id: String, _ quiet: Bool) throws -> PaperSourceRecord? {
        try store.updatePaperSource(id: id) { $0.isQuiet = quiet }
    }

    /// Unfollow leaves every paper already added in the Library; it returns the record for Undo.
    @discardableResult
    public func unfollow(id: String) throws -> PaperSourceRecord? {
        let record = try store.loadPaperSources().first { $0.id == id }
        try store.deletePaperSource(id: id)
        return record
    }

    public func restore(_ record: PaperSourceRecord) throws {
        try store.savePaperSource(record)
    }

    static func fallbackTitle(_ source: PaperSource) -> String {
        switch source {
        case .zoteroGroup: return "Zotero library"
        case .zoteroUser: return PaperSourceFetcher.ownLibraryTitle
        case .pubMedRSS: return "PubMed search"
        }
    }
}

/// A paper source's screen: its header words and one row per paper with the button it offers.
public enum PaperSourceScreen {
    public enum Button: Equatable, Sendable {
        case add
        case adding
        case inLibrary(itemId: String)
        /// Nil only when the record names no address.
        case open(URL?)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var entry: PaperEntry
        public var status: PaperEntryStatus
        public var button: Button
        public var id: String { entry.id }

        /// "PDF", "Abstract only" or "Link only", always with an icon (never colour alone).
        public var statusTitle: String { PaperSourceScreen.statusTitle(status) }
        public var statusSymbol: String { PaperSourceScreen.statusSymbol(status) }

        public var buttonTitle: String {
            switch button {
            case .add: return "Add"
            case .adding: return "Adding…"
            case .inLibrary: return "In Library"
            case .open: return "Open"
            }
        }

        public var accessibilityLabel: String {
            [entry.title, entry.citationLine, statusTitle, button == .adding ? "Adding" : nil].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    public static func statusTitle(_ status: PaperEntryStatus) -> String {
        switch status {
        case .pdf: return "PDF"
        case .abstractOnly: return "Abstract only"
        case .linkOnly: return "Link only"
        }
    }

    public static func statusSymbol(_ status: PaperEntryStatus) -> String {
        switch status {
        case .pdf: return "doc.fill"
        case .abstractOnly: return "text.alignleft"
        case .linkOnly: return "link"
        }
    }

    /// "Zotero collection", "Zotero library" or "PubMed search".
    public static func kindLine(_ source: PaperSource) -> String {
        switch source {
        case .zoteroGroup(_, let key), .zoteroUser(_, let key): return key == nil ? "Zotero library" : "Zotero collection"
        case .pubMedRSS: return "PubMed search"
        }
    }

    public static let emptyText = "No papers in this collection yet."

    /// The empty line for a list of this kind: a PubMed search has no collection.
    public static func emptyText(for source: PaperSource) -> String {
        source.provider == .pubmed ? "No papers in this search yet." : emptyText
    }
    /// Above the papers when the list couldn't be read because the phone is offline: Following's own offline line.
    public static let offlineSnapshotLine = "Showing the last local snapshot"

    /// The rows, newest joined first.
    /// - Parameters:
    ///   - index: the Library's DOI and address index, built when the screen opened; nil until it is.
    ///   - added: papers added from this screen since it opened, by entry id: the index predates them.
    ///   - adding: papers whose Add is under way.
    ///   - pdfFailed: papers whose PDF couldn't be fetched this time; with no abstract their button becomes Open.
    ///   - connectedUserID: a stored PDF of the listener's own library is reachable only while that user's key is
    ///     connected.
    public static func rows(
        record: PaperSourceRecord, index: PaperLibraryIndex?, added: [String: String] = [:], adding: Set<String>,
        pdfFailed: Set<String>, connectedUserID: Int?
    ) -> [Row] {
        record.entries.map { stored in
            var entry = stored
            if entry.zoteroUserID == nil || entry.zoteroUserID != connectedUserID { entry.storedPDFReachable = false }
            let existing = added[entry.id] ?? index?.itemId(for: entry)
            let button: Button
            if let existing {
                button = .inLibrary(itemId: existing)
            } else if adding.contains(entry.id) {
                button = .adding
            } else {
                let route = pdfFailed.contains(entry.id)
                    ? PaperEntryImportRoute.afterPDFFailed(for: entry)
                    : PaperEntryImportRoute.route(for: entry, existingItemId: nil)
                if case .open(let url) = route { button = .open(url) } else { button = .add }
            }
            return Row(entry: entry, status: entry.status, button: button)
        }
    }
}
