import Combine
import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitSharing

/// Finds the episode a private-feed packet's Margins belong to, from the feed link the listener
/// pastes, and adds it to their Library (#454). The packet carries no link, so the listener's own
/// feed is the only way to the episode. This type reads that feed, asks `SharedEpisodeFeedMatcher`
/// which episode it is, and never guesses between two. The pasted link is used for one fetch and
/// then dropped: it is kept nowhere, not in the Library, a diagnostic or anything shared later.
@MainActor
final class SharedEpisodeRecovery: ObservableObject {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
    }

    enum Phase: Equatable {
        case idle
        case checking
        /// The feed holds no episode that matches.
        case noMatch
        /// Several episodes match; the listener picks.
        case choose([Candidate])
        case added(itemId: String)
        case failed(String)
    }

    /// What the recovery needs from the app. The model's own import path is behind these.
    struct Services {
        var fetchFeed: @Sendable (URL) async throws -> ParsedFeed
        /// The Library item that already is this episode and that the packet's item will accept, if there is one.
        var existingEpisode: @MainActor (SharedItemIdentity, FeedEntry, String?) async throws -> String?
        var addEpisode: @MainActor (FeedEntry, String?) async throws -> String
        /// Called once the episode is in the Library, so the pending import looks for it again.
        var episodeReady: @MainActor () -> Void
    }

    static let invalidLinkMessage = "That doesn't look like a feed link. Paste the link that starts with https://."
    static let noAudioMessage = "That episode has no audio in your feed, so it can't be added."

    @Published private(set) var phase: Phase = .idle

    private let services: Services
    private var candidates: [String: (shared: SharedItemIdentity, episode: ParsedFeedItem, showTitle: String)] = [:]
    private var generation = 0

    init(services: Services) {
        self.services = services
    }

    /// Back to the start, for a new packet or a cancelled import. Work still in flight is ignored.
    func reset() {
        generation += 1
        candidates = [:]
        phase = .idle
    }

    /// Reads the pasted feed and finds `shared`'s episode in it.
    func recover(_ shared: SharedItemIdentity, feedLink: String) async {
        guard phase != .checking else { return }
        guard let url = Self.feedURL(from: feedLink) else {
            phase = .failed(Self.invalidLinkMessage)
            return
        }
        generation += 1
        let current = generation
        candidates = [:]
        phase = .checking
        let feed: ParsedFeed
        do {
            feed = try await services.fetchFeed(url)
        } catch {
            guard current == generation else { return }
            phase = .failed(Self.message(for: error))
            return
        }
        guard current == generation else { return }
        let episodes = Self.importableEpisodes(for: shared, in: feed)
        switch episodes.count {
        case 0:
            phase = .noMatch
        case 1:
            await add(episodes[0], for: shared, showTitle: feed.title, generation: current)
        default:
            for (index, episode) in episodes.enumerated() {
                candidates["\(index)"] = (shared, episode, feed.title)
            }
            phase = .choose(episodes.enumerated().map { Self.candidate(id: "\($0.offset)", for: $0.element) })
        }
    }

    /// The listener's pick among several matching episodes.
    func choose(_ candidateID: String) async {
        guard case .choose = phase, let pick = candidates[candidateID] else { return }
        generation += 1
        candidates = [:]
        phase = .checking
        await add(pick.episode, for: pick.shared, showTitle: pick.showTitle, generation: generation)
    }

    private func add(_ episode: ParsedFeedItem, for shared: SharedItemIdentity, showTitle: String, generation current: Int) async {
        guard let entry = SharedEpisodeFeedEntry.entry(for: episode) else {
            phase = .failed(Self.noAudioMessage)
            return
        }
        do {
            let itemId: String
            if let existing = try await services.existingEpisode(shared, entry, showTitle) {
                itemId = existing
            } else {
                itemId = try await services.addEpisode(entry, showTitle)
            }
            guard current == generation else { return }
            phase = .added(itemId: itemId)
            services.episodeReady()
        } catch {
            guard current == generation else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: Pure helpers

    /// The feed's episodes that match `shared` and that the pending import will accept once added. The
    /// feed matcher accepts a title alone; the import also wants the show or the day behind it, so an
    /// episode only the matcher likes would be added and then refused (#454 audit).
    static func importableEpisodes(for shared: SharedItemIdentity, in feed: ParsedFeed) -> [ParsedFeedItem] {
        let matches: [ParsedFeedItem]
        switch SharedEpisodeFeedMatcher.match(shared, in: feed) {
        case .none: return []
        case .matched(let episode): matches = [episode]
        case .several(let episodes): matches = episodes
        }
        return matches.filter { episode in
            // An episode with nothing to add stays, so the listener hears why it can't be added.
            guard let entry = SharedEpisodeFeedEntry.entry(for: episode) else { return true }
            return RecoveredEpisodeMatch.accepts(shared, entry: entry, showTitle: feed.title)
        }
    }

    /// The https address in what the listener pasted. `feed://` and the podcast-app schemes mean https.
    static func feedURL(from text: String) -> URL? {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["feed", "itpc", "pcast"] where link.lowercased().hasPrefix("\(scheme):") {
            link = String(link.dropFirst(scheme.count + 1))
            if link.hasPrefix("//") { link = "https:" + link }
        }
        guard let url = URL(string: link), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func message(for error: Error) -> String {
        if error is URLError {
            return "Spoken Margins couldn't reach that feed. Check your connection and the link, then try again."
        }
        if error is FeedParserError {
            return "That link isn't a podcast feed Spoken Margins can read."
        }
        return "Spoken Margins couldn't add that episode. Try again."
    }

    static func candidate(id: String, for episode: ParsedFeedItem) -> Candidate {
        var parts: [String] = []
        if let published = episode.publishedAt {
            parts.append(published.formatted(date: .abbreviated, time: .omitted))
        }
        if let minutes = episode.durationMs.map({ ($0 + 30_000) / 60_000 }), minutes > 0 {
            parts.append("\(minutes) min")
        }
        return Candidate(id: id, title: episode.title, detail: parts.joined(separator: " · "))
    }

    /// The live services: the feed over the network and the Library through `model`.
    static func services(model: Gate1AppModel) -> Services {
        Services(
            fetchFeed: { try await SharedEpisodeFeedFetcher.fetch($0) },
            existingEpisode: { [weak model] shared, entry, showTitle in
                try await model?.libraryItemID(forRecoveredEpisode: entry, showTitle: showTitle, acceptedBy: shared)
            },
            addEpisode: { [weak model] entry, showTitle in
                guard let model else { throw CancellationError() }
                return try await model.addRecoveredSharedEpisode(entry, showTitle: showTitle)
            },
            episodeReady: { [weak model] in model?.refreshSpokenMarginsPackageImportAfterAddingSource() }
        )
    }
}

/// One bounded read of a feed the listener pasted.
enum SharedEpisodeFeedFetcher {
    static func fetch(_ url: URL) async throws -> ParsedFeed {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(
            "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml",
            forHTTPHeaderField: "Accept"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= FeedParserLimits.defaultMaximumBytes else { throw FeedParserError.responseTooLarge }
        return try FeedParser().parse(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }
}
