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
    /// Tests replace it, since Type III Audio's find call (LessWrong and EA Forum posts, #3438) is otherwise the network.
    var fetchNarration: TypeIIIAudioNarration.Fetch
    /// Each recently shared item's latest outcome, so a later share doesn't hide an earlier post's.
    private var log = SharedPostVoiceoverLog()
    /// Items looked up (or being looked up) in this launch. A failed lookup, or one that found the narration
    /// still pending (#3297), leaves it, so opening or playing the item tries again.
    private var ledger = VoiceoverLookupLedger()
    /// Tests set the clock to step past the wait before a "not yet" retry.
    var now: () -> Date = { Date() }

    /// True once per item and launch (and again after a failed or "not yet" lookup), so opening an item can't repeat a lookup.
    func mayLookUp(itemId: String) -> Bool { ledger.mayLookUp(itemId: itemId, now: now()) }

    /// Marks the item as looked up before any lookup task starts, and says whether this caller may start one.
    /// A clip made during playback opens its item (#1437), which also asks for a lookup; claiming at once, not
    /// inside the task, keeps that to one page fetch (Claude audit on 34af58c).
    func claim(itemId: String) -> Bool { ledger.claim(itemId: itemId, now: now()) }

    init(
        fetchPage: @escaping FetchPage = SharedLinkVoiceover.fetchFromNetwork,
        fetchNarration: @escaping TypeIIIAudioNarration.Fetch = SharedLinkVoiceover.narrationFromNetwork
    ) {
        self.fetchPage = fetchPage
        self.fetchNarration = fetchNarration
    }

    /// Looks for the voiceover of the post at `sharedURL` (or the address the article was read from) and
    /// saves it for `itemId`. `fetched` holds the pages the link resolver read for this import. `report` gets
    /// the log's summary, one `<itemId>: <status>` line per recently shared item, after each change. The
    /// status is `saved`, `none:<reason>` (the page was read and has no recording to keep; `generated_voice_paywalled`
    /// is a paid post's automatic narration; `generated_voice_pending` and `voiceover_processing` mean not ready yet,
    /// so a later open or play looks again, #3297), `not_substack`, `item removed` or `failed:<reason>`,
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
            ledger.record(status: status, itemId: itemId, now: now())
            log.record(status, for: itemId)
            report(log.summary)
        }
        let fetchPage = fetchPage
        let fetchNarration = fetchNarration
        let articleURL = article.source.url
        // Off the main thread: a post page can run to a few hundred KB.
        let outcome = await Task.detached(priority: .utility) {
            await SharedPostVoiceoverLookup.find(
                sharedURL: sharedURL, articleURL: articleURL, itemId: itemId, fetched: fetched, fetchPage: fetchPage,
                fetchNarration: fetchNarration
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
            // The item check, the earlier text map and the save run in order on one background task, off the main
            // actor (#2507). The listener may have removed the article while the page loaded.
            let saved = try await StoreReader(store).read { try $0.savePublisherAudioIfItemExists(found) }
            guard let audio = saved else { return note("item removed") }
            note("saved")
            PublisherAudioTextMapper.start(audio, store: store, transcriber: transcriber) { note($0) }
        } catch {
            note("failed:\(SafeErrorText.describe(error))")
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

    /// Type III Audio's find call: one GET, no cookies, no stored response, no header of ours beyond the system's own.
    nonisolated static func narrationFromNetwork(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= TypeIIIAudioNarration.maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, http.statusCode)
    }
}

/// Type III's find call is answered where it was sent: a redirect would carry the post's address to another host.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
