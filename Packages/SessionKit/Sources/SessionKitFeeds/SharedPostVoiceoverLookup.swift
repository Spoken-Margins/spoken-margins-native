import Foundation
import SessionKit

/// The pages one link import has already fetched, so later steps read them instead of asking the network
/// again (#810). The link resolver fills it (`PublicPodcastLinkResolver.remembering(_:)`) and the shared
/// post's voiceover lookup reads it. Make one per import; it holds every response until it is released.
public final class FetchedPageMemo: @unchecked Sendable {
    /// A fetched body and the address it ended at after redirects. A fetch that can't see redirects (the
    /// resolver's synchronous or injected fetches) records the address it asked for.
    public struct Page: Equatable, Sendable {
        public let data: Data
        public let finalURL: URL
    }

    private let lock = NSLock()
    private var pages: [URL: Page] = [:]

    public init() {}

    public func page(for url: URL) -> Page? {
        lock.withLock { pages[url] }
    }

    @discardableResult
    public func remember(_ data: Data, for url: URL, finalURL: URL? = nil) -> Data {
        lock.withLock { pages[url] = Page(data: data, finalURL: finalURL ?? url) }
        return data
    }
}

/// Finds the voiceover of a Substack post shared as a link, or pasted into the Link field (#810). The post page
/// is read from what the link resolver already fetched; only when it fetched nothing for that address (the
/// address is the article's, not the shared one) is the page fetched, once. Substack addresses only.
public enum SharedPostVoiceoverLookup {
    /// Fetches a page and returns its HTML and the address it ended at after redirects.
    public typealias FetchPage = @Sendable (URL) async throws -> (html: String, finalURL: URL)

    public enum Outcome: Equatable, Sendable {
        case notSubstack
        case failed(String)
        case none
        case found(PublisherAudio)
    }

    public static let maximumPageBytes = 4 * 1_024 * 1_024

    public static func find(
        sharedURL: URL,
        articleURL: String,
        itemId: String,
        fetched: FetchedPageMemo?,
        fetchPage: FetchPage
    ) async -> Outcome {
        let candidates = [sharedURL, URL(string: articleURL)].compactMap { $0 }
        guard let pageURL = candidates.first(where: PublisherNarrationEvidence.mayHaveVoiceover) else { return .notSubstack }
        let html: String
        let finalURL: URL
        if let page = fetched?.page(for: pageURL) {
            guard page.finalURL.scheme?.lowercased() == "https" else { return .failed(URLError(.secureConnectionFailed).localizedDescription) }
            guard page.data.count <= maximumPageBytes else { return .failed(URLError(.dataLengthExceedsMaximum).localizedDescription) }
            (html, finalURL) = (String(decoding: page.data, as: UTF8.self), page.finalURL)
        } else {
            do {
                (html, finalURL) = try await fetchPage(pageURL)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        guard let audio = PublisherNarrationEvidence.publisherAudio(postPage: html, finalURL: finalURL, itemId: itemId) else { return .none }
        return .found(audio)
    }
}
