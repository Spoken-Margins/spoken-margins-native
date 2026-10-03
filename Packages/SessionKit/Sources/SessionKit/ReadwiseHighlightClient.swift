import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One Margin as a Readwise highlight (#172): the passage around the Margin is the highlight,
/// the Margin itself is its note, filed under the item's title and source link.
public struct ReadwiseHighlight: Equatable, Sendable {
    /// Session id and Margin id: Margin ids repeat across sessions, so neither alone is unique.
    public var marginKey: String
    /// The Spoken Margins item the Margin belongs to, so Readwise's reply can be linked back to it (#623).
    public var itemId: String
    public var text: String
    public var note: String
    public var title: String
    public var author: String?
    public var sourceURL: String?
    public var category: String
    public var highlightedAt: Date

    // Readwise's documented field limits; longer values are cut rather than rejected by the API.
    static let textLimit = 8_191
    static let titleLimit = 511
    static let authorLimit = 1_024
    static let sourceURLLimit = 2_047

    public static func key(sessionId: String, marginId: String) -> String { sessionId + ":" + marginId }

    /// Builds the highlight from a one-Margin export (the one the notes folder and "Copy with Context" use).
    /// Returns nil for a Margin with no text yet, such as a recording still being transcribed, so it is
    /// sent once its transcript arrives rather than as an empty note.
    public init?(export: SessionExport, createdAt: Date) {
        guard export.interjections.count == 1, let margin = export.interjections.first else { return nil }
        let note = (margin.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return nil }
        let excerpt = [margin.anchorBefore, margin.anchorAfter]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        marginKey = Self.key(sessionId: margin.sessionId, marginId: margin.id)
        itemId = export.item.id
        text = String((excerpt.isEmpty ? note : excerpt).prefix(Self.textLimit))
        self.note = String(note.prefix(Self.textLimit))
        let trimmedTitle = export.item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = String((trimmedTitle.isEmpty ? "Spoken Margins" : trimmedTitle).prefix(Self.titleLimit))
        author = export.item.author.map { String($0.prefix(Self.authorLimit)) }
        // The item's page first, then its media link. Both pass the policy again, so a private feed
        // link never leaves the device even if the export was built without the engine's filter.
        sourceURL = [export.item.externalReference, export.item.sourceURL]
            .lazy
            .compactMap { ShareableLinkPolicy.shareableLink($0) }
            .first { $0.count <= Self.sourceURLLimit }
        let isPodcast = [AudioSourceType.nativeMediaFile.rawValue, AudioSourceType.remoteStream.rawValue]
            .contains(export.item.mediaSourceType ?? "")
        category = isPodcast ? "podcasts" : "articles"
        highlightedAt = createdAt
    }
}

public enum ReadwiseHighlightError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case tokenRejected
    case rateLimited
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidToken: return "Enter a valid Readwise access token."
        case .tokenRejected: return "Readwise rejected the token. Reconnect in Settings."
        case .rateLimited: return "Readwise asked to slow down. Unsent Margins go on the next try."
        case .httpStatus(let code): return "Readwise returned HTTP \(code). Unsent Margins go on the next try."
        }
    }
}

/// Posts highlights to Readwise's v2 API with the token the listener entered for Reader.
public struct ReadwiseHighlightClient: Sendable {
    public typealias Transport = ReadLaterClient.Transport
    public static let endpoint = URL(string: "https://readwise.io/api/v2/highlights/")!
    let transport: Transport
    public init(transport: @escaping Transport) { self.transport = transport }

    /// Returns the books Readwise says it filed the highlights under, or nil when its reply can't be read.
    @discardableResult
    public func send(_ highlights: [ReadwiseHighlight], token: String) async throws -> [ReadwiseBook]? {
        guard !highlights.isEmpty else { return [] }
        let (data, response) = try await transport(try Self.request(for: highlights, token: token))
        switch response.statusCode {
        case 200..<300: return try? JSONDecoder().decode([ReadwiseBook].self, from: data)
        case 401, 403: throw ReadwiseHighlightError.tokenRejected
        case 429: throw ReadwiseHighlightError.rateLimited
        default: throw ReadwiseHighlightError.httpStatus(response.statusCode)
        }
    }

    static func request(for highlights: [ReadwiseHighlight], token: String) throws -> URLRequest {
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw ReadwiseHighlightError.invalidToken }
        struct Body: Encodable {
            struct Highlight: Encodable {
                let text: String; let note: String; let title: String; let author: String?
                let source_url: String?; let category: String; let highlighted_at: String
            }
            let highlights: [Highlight]
        }
        let formatter = ISO8601DateFormatter()
        let body = Body(highlights: highlights.map {
            .init(text: $0.text, note: $0.note, title: $0.title, author: $0.author, source_url: $0.sourceURL,
                  category: $0.category, highlighted_at: formatter.string(from: $0.highlightedAt))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Token " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }
}

/// One book in Readwise's reply to a send: the title the highlights were filed under, the highlights
/// it added or updated, and its page on readwise.io (#623).
public struct ReadwiseBook: Decodable, Equatable, Sendable {
    public var title: String
    public var highlightsURL: String?
    /// Nil when the reply leaves the field out, which isn't the same as listing none.
    public var modifiedHighlights: [Int]?

    public init(title: String, highlightsURL: String?, modifiedHighlights: [Int]?) {
        self.title = title
        self.highlightsURL = highlightsURL
        self.modifiedHighlights = modifiedHighlights
    }

    private enum CodingKeys: String, CodingKey {
        case title, highlightsURL = "highlights_url", modifiedHighlights = "modified_highlights"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        highlightsURL = try? container.decodeIfPresent(String.self, forKey: .highlightsURL)
        modifiedHighlights = try? container.decodeIfPresent([Int].self, forKey: .modifiedHighlights)
    }

    /// The book's readwise.io page, only when it is an https link on readwise.io itself.
    public var readwiseLink: URL? {
        guard let highlightsURL, let url = URL(string: highlightsURL), url.scheme == "https",
              let host = url.host?.lowercased(), host == "readwise.io" || host.hasSuffix(".readwise.io")
        else { return nil }
        return url
    }

    /// Readwise filed the highlights here: it listed some, or didn't say.
    var listsHighlights: Bool { modifiedHighlights.map { !$0.isEmpty } ?? true }
}

/// The Margins Readwise has accepted, as a JSON file beside the database rather than in it,
/// so the Build 29 database is untouched and a Margin is never sent twice. Each item's readwise.io
/// page sits in the same file (#623); Build 29 reads the file and ignores the links.
public struct ReadwiseSentLedger: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    private struct File: Codable {
        var sent: [String]
        /// Item id to its page on readwise.io.
        var links: [String: String]?
    }

    private func load() throws -> File {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return File(sent: []) }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))
    }

    public func sentKeys() throws -> Set<String> { Set(try load().sent) }

    /// Each item's readwise.io page, for the items whose Margins were sent since links were kept.
    public func links() throws -> [String: URL] {
        (try load().links ?? [:]).compactMapValues { URL(string: $0) }
    }

    public func record<Keys: Sequence>(_ keys: Keys, links newLinks: [String: URL] = [:]) throws where Keys.Element == String {
        var file = try load()
        file.sent = Set(file.sent).union(keys).sorted()
        if !newLinks.isEmpty {
            file.links = (file.links ?? [:]).merging(newLinks.mapValues(\.absoluteString)) { _, new in new }
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
    }

    /// Links each item in a sent batch to the book Readwise filed its highlights under: by title, or
    /// directly when the batch holds one item and Readwise answered with one book.
    static func links(for batch: [ReadwiseHighlight], books: [ReadwiseBook]) -> [String: URL] {
        let itemIds = Set(batch.map(\.itemId))
        if itemIds.count == 1, books.count == 1, let itemId = itemIds.first, let url = books[0].readwiseLink {
            return [itemId: url]
        }
        func normalized(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var urlsByTitle: [String: URL] = [:]
        for book in books { if let url = book.readwiseLink { urlsByTitle[normalized(book.title)] = url } }
        var result: [String: URL] = [:]
        for highlight in batch { if let url = urlsByTitle[normalized(highlight.title)] { result[highlight.itemId] = url } }
        return result
    }
}

/// What one pass sent, for the status line under the toggle (#623).
public struct ReadwiseSyncReport: Equatable, Sendable {
    /// Margins Readwise accepted.
    public var sent: Int
    /// Of those, the ones in batches whose reply listed no highlights.
    public var unlisted: Int
    /// Items the sent Margins belong to.
    public var itemCount: Int
    /// The title of the item with the most recent sent Margin.
    public var latestTitle: String?

    public init(sent: Int = 0, unlisted: Int = 0, itemCount: Int = 0, latestTitle: String? = nil) {
        self.sent = sent
        self.unlisted = unlisted
        self.itemCount = itemCount
        self.latestTitle = latestTitle
    }

    /// One sentence naming what was sent, or nil when the pass sent nothing.
    public var summary: String? {
        guard sent > 0 else { return nil }
        if unlisted == sent {
            return "Readwise accepted \(Self.margins(sent)) but didn't list any highlights. Check your Readwise account."
        }
        let title = latestTitle.map(Self.shortTitle) ?? "your items"
        var line = itemCount <= 1
            ? "\(Self.margins(sent)) sent to Readwise under \u{201C}\(title)\u{201D}."
            : "\(Self.margins(sent)) sent to Readwise across \(itemCount) items, most recently \u{201C}\(title)\u{201D}."
        if unlisted > 0 { line += " Readwise didn't list \(unlisted) of them." }
        return line
    }

    /// The status line: the last send's summary and when it happened, then when Readwise was last checked.
    public static func statusLine(lastSummary: String?, sentAt: String?, checkedAt: String) -> String {
        guard let lastSummary else { return "No new Margins to send. Last checked \(checkedAt)." }
        let when = sentAt.map { " Sent \($0)." } ?? ""
        return lastSummary + when + " Last checked \(checkedAt)."
    }

    static func margins(_ count: Int) -> String { count == 1 ? "1 Margin" : "\(count) Margins" }

    static func shortTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 40 ? trimmed : String(trimmed.prefix(39)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

public enum ReadwiseHighlightSyncPass {
    /// Sends every highlight the ledger hasn't recorded, a batch at a time, and records each batch
    /// once Readwise accepts it. A failure stops the pass; the next pass sends only what's left.
    /// Returns what was sent, and records each item's readwise.io page from Readwise's reply.
    public static func run(
        _ highlights: [ReadwiseHighlight], token: String, client: ReadwiseHighlightClient,
        ledger: ReadwiseSentLedger, batchSize: Int = 50
    ) async throws -> ReadwiseSyncReport {
        var seen = try ledger.sentKeys()
        let pending = highlights.filter { seen.insert($0.marginKey).inserted }
        var report = ReadwiseSyncReport()
        var items = Set<String>()
        var latest: ReadwiseHighlight?
        for start in stride(from: 0, to: pending.count, by: max(1, batchSize)) {
            try Task.checkCancellation()
            let batch = Array(pending[start..<min(start + max(1, batchSize), pending.count)])
            let books = try await client.send(batch, token: token)
            try ledger.record(batch.map(\.marginKey), links: ReadwiseSentLedger.links(for: batch, books: books ?? []))
            report.sent += batch.count
            // An unreadable reply says nothing either way; only a reply listing no highlights counts against it.
            if let books, !books.contains(where: \.listsHighlights) { report.unlisted += batch.count }
            items.formUnion(batch.map(\.itemId))
            for highlight in batch where latest.map({ highlight.highlightedAt >= $0.highlightedAt }) ?? true {
                latest = highlight
            }
        }
        report.itemCount = items.count
        report.latestTitle = latest?.title
        return report
    }
}

public enum ReadwiseHighlightGatherer {
    /// Builds a highlight for each active Margin on a live item, skipping Margins already sent.
    public static func highlights(
        sessions: [Session], repository: SessionRepository, skipping sent: Set<String> = []
    ) throws -> [ReadwiseHighlight] {
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "readwise-highlights", displayName: "Readwise highlights", capabilities: [:]),
            repository: repository
        )
        var highlights: [ReadwiseHighlight] = []
        for session in sessions {
            guard let item = try? repository.loadItem(id: session.itemId), item.deletedAt == nil else { continue }
            for margin in try repository.loadInterjections(sessionId: session.id) where margin.status == "active" {
                guard !sent.contains(ReadwiseHighlight.key(sessionId: session.id, marginId: margin.id)) else { continue }
                let export = try engine.buildExport(options: ExportOptions(
                    sessionId: session.id,
                    includeFullText: false, includeReference: true, includeListeningMap: false,
                    includeInterjections: true, includeTurns: false,
                    scope: "selected_interjections", interjectionIds: [margin.id]
                ))
                if let highlight = ReadwiseHighlight(export: export, createdAt: margin.recordedAt(in: session)) {
                    highlights.append(highlight)
                }
            }
        }
        return highlights
    }
}
