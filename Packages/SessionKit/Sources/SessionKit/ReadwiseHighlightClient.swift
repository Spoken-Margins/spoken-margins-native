import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One Margin as a Readwise highlight (#172): the passage around the Margin is the highlight,
/// the Margin itself is its note, filed under the item's title and source link.
public struct ReadwiseHighlight: Equatable, Sendable {
    /// Session id and Margin id: Margin ids repeat across sessions, so neither alone is unique.
    public var marginKey: String
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

    public func send(_ highlights: [ReadwiseHighlight], token: String) async throws {
        guard !highlights.isEmpty else { return }
        let (_, response) = try await transport(try Self.request(for: highlights, token: token))
        switch response.statusCode {
        case 200..<300: return
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

/// The Margins Readwise has accepted, as a JSON file beside the database rather than in it,
/// so the Build 29 database is untouched and a Margin is never sent twice.
public struct ReadwiseSentLedger: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    private struct File: Codable { var sent: [String] }

    public func sentKeys() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return Set(try JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL)).sent)
    }

    public func record<Keys: Sequence>(_ keys: Keys) throws where Keys.Element == String {
        let all = try sentKeys().union(keys)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(File(sent: all.sorted())).write(to: fileURL, options: .atomic)
    }
}

public enum ReadwiseHighlightSyncPass {
    /// Sends every highlight the ledger hasn't recorded, a batch at a time, and records each batch
    /// once Readwise accepts it. A failure stops the pass; the next pass sends only what's left.
    /// Returns how many highlights were sent.
    public static func run(
        _ highlights: [ReadwiseHighlight], token: String, client: ReadwiseHighlightClient,
        ledger: ReadwiseSentLedger, batchSize: Int = 50
    ) async throws -> Int {
        var seen = try ledger.sentKeys()
        let pending = highlights.filter { seen.insert($0.marginKey).inserted }
        var sent = 0
        for start in stride(from: 0, to: pending.count, by: max(1, batchSize)) {
            try Task.checkCancellation()
            let batch = Array(pending[start..<min(start + max(1, batchSize), pending.count)])
            try await client.send(batch, token: token)
            try ledger.record(batch.map(\.marginKey))
            sent += batch.count
        }
        return sent
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
                if let highlight = ReadwiseHighlight(export: export, createdAt: margin.createdAt) {
                    highlights.append(highlight)
                }
            }
        }
        return highlights
    }
}
