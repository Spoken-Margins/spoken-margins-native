import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// A Substack post shared as a link, or pasted into the Link field, keeps the post's own voiceover beside the
/// article, as a followed post does (#810). After the article is imported, the post page the link resolver
/// already fetched is read (`SharedPostVoiceoverLookup`); the page is fetched only when the resolver didn't.
/// A completed voiceover of that same post is saved as the item's `publisher_audio` record, and its
/// text-to-time map is started. A failed fetch leaves the article as it is.
@MainActor
final class SharedLinkVoiceover {
    typealias FetchPage = SharedPostVoiceoverLookup.FetchPage

    /// Tests replace it, since the share path's page fetch is otherwise the network.
    var fetchPage: FetchPage

    init(fetchPage: @escaping FetchPage = SharedLinkVoiceover.fetchFromNetwork) {
        self.fetchPage = fetchPage
    }

    /// Looks for the voiceover of the post at `sharedURL` (or the address the article was read from) and
    /// saves it for `itemId`. `fetched` holds the pages the link resolver read for this import. `report` gets
    /// one diagnostic: `saved`, `none`, `not_substack`, `item removed` or `failed:<reason>`, and the text
    /// map's progress after a save.
    func remember(
        sharedURL: URL,
        article: BrowserTextHandoff,
        itemId: String,
        fetched: FetchedPageMemo?,
        store: SQLiteSessionStore,
        transcriber: any SourceTranscriptionClient,
        report: @escaping @MainActor (String) -> Void
    ) async {
        let fetchPage = fetchPage
        let articleURL = article.source.url
        // Off the main thread: a post page can run to a few hundred KB.
        let outcome = await Task.detached(priority: .utility) {
            await SharedPostVoiceoverLookup.find(
                sharedURL: sharedURL, articleURL: articleURL, itemId: itemId, fetched: fetched, fetchPage: fetchPage
            )
        }.value
        let found: PublisherAudio
        switch outcome {
        case .notSubstack: return report("\(itemId): not_substack")
        case .failed(let reason): return report("\(itemId): failed:\(reason)")
        case .none: return report("\(itemId): none")
        case .found(let audio): found = audio
        }
        do {
            // The listener may have removed the article while the page loaded.
            guard (try? store.loadItem(id: itemId)) != nil else { return report("\(itemId): item removed") }
            let audio = found.keepingTextMap(of: try store.loadPublisherAudio(itemId: itemId))
            try store.savePublisherAudio(audio)
            report("\(itemId): saved")
            PublisherAudioTextMapper.start(audio, store: store, transcriber: transcriber) { report("\(itemId): \($0)") }
        } catch {
            report("\(itemId): failed:\(String(describing: error))")
        }
    }

    nonisolated static func fetchFromNetwork(_ url: URL) async throws -> (html: String, finalURL: URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let finalURL = http.url, finalURL.scheme?.lowercased() == "https" else { throw URLError(.secureConnectionFailed) }
        guard data.count <= SharedPostVoiceoverLookup.maximumPageBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return (String(decoding: data, as: UTF8.self), finalURL)
    }
}
