import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// A Substack post shared as a link, or pasted into the Link field, keeps the post's own voiceover beside the
/// article, as a followed post does (#810). After the article is imported, the post page the link resolver
/// already fetched is read (`SharedPostVoiceoverLookup`); the page is fetched only when the resolver didn't.
/// A completed voiceover of that same post, or failing that Substack's automatic narration of it (owner's call,
/// 2026-10-14), is saved as the item's `publisher_audio` record, and its
/// text-to-time map is started. A failed fetch leaves the article as it is.
@MainActor
final class SharedLinkVoiceover {
    typealias FetchPage = SharedPostVoiceoverLookup.FetchPage

    /// Tests replace it, since the share path's page fetch is otherwise the network.
    var fetchPage: FetchPage
    /// Each recently shared item's latest outcome, so a later share doesn't hide an earlier post's.
    private var log = SharedPostVoiceoverLog()
    /// Items looked up (or being looked up) in this launch. A failed lookup leaves it, so reconnecting and
    /// opening the item tries again.
    private var settled = Set<String>()

    /// True once per item and launch (and again after a failed lookup), so opening an item can't repeat a lookup.
    func mayLookUp(itemId: String) -> Bool { !settled.contains(itemId) }

    /// Marks the item as looked up before any lookup task starts, and says whether this caller may start one.
    /// A clip made during playback opens its item (#1437), which also asks for a lookup; claiming at once, not
    /// inside the task, keeps that to one page fetch (Claude audit on 34af58c).
    func claim(itemId: String) -> Bool { settled.insert(itemId).inserted }

    init(fetchPage: @escaping FetchPage = SharedLinkVoiceover.fetchFromNetwork) {
        self.fetchPage = fetchPage
    }

    /// Looks for the voiceover of the post at `sharedURL` (or the address the article was read from) and
    /// saves it for `itemId`. `fetched` holds the pages the link resolver read for this import. `report` gets
    /// the log's summary, one `<itemId>: <status>` line per recently shared item, after each change. The
    /// status is `saved`, `none:<reason>` (the page was read and has no recording to keep; `generated_voice_paywalled`
    /// is a paid post's automatic narration), `not_substack`, `item removed` or `failed:<reason>`,
    /// then the text map's progress after a save.
    func remember(
        sharedURL: URL,
        article: BrowserTextHandoff,
        itemId: String,
        fetched: FetchedPageMemo?,
        store: SQLiteSessionStore,
        transcriber: any SourceTranscriptionClient,
        report: @escaping @MainActor (String) -> Void
    ) async {
        let note: @MainActor (String) -> Void = { [weak self] status in
            guard let self else { return }
            if status.hasPrefix("failed:") { settled.remove(itemId) }
            log.record(status, for: itemId)
            report(log.summary)
        }
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
        case .notSubstack: return note("not_substack")
        case .failed(let reason): return note("failed:\(reason)")
        case .noVoiceover(let reason): return note("none:\(reason)")
        case .found(let audio): found = audio
        }
        do {
            // The listener may have removed the article while the page loaded.
            guard (try? store.loadItem(id: itemId)) != nil else { return note("item removed") }
            let audio = found.keepingTextMap(of: try store.loadPublisherAudio(itemId: itemId))
            try store.savePublisherAudio(audio)
            note("saved")
            PublisherAudioTextMapper.start(audio, store: store, transcriber: transcriber) { note($0) }
        } catch {
            note("failed:\(String(describing: error))")
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
