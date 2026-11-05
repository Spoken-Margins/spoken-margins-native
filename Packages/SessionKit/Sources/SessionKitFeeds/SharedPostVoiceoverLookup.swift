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
/// is read from what the link resolver already fetched, when that page is at a Substack or `/p/<slug>` address or
/// declares Substack's `_preloads`. Only when the resolver read no such page is the page fetched, once, and only
/// for a Substack or `/p/<slug>` address (`PublisherNarrationEvidence.mayHaveVoiceover`).
public enum SharedPostVoiceoverLookup {
    /// Fetches a page and returns its HTML and the address it ended at after redirects.
    public typealias FetchPage = @Sendable (URL) async throws -> (html: String, finalURL: URL)

    public enum Outcome: Equatable, Sendable {
        case notSubstack
        case failed(String)
        /// The page was read and has no voiceover for this post. `reason` is a short token
        /// (`PublisherNarrationEvidence.absence`), so diagnostics say why.
        case noVoiceover(reason: String)
        case found(PublisherAudio)
    }

    public static let maximumPageBytes = 4 * 1_024 * 1_024

    /// A LessWrong or EA Forum post (#3438) is not read as a page: Type III Audio's narration is found with one call
    /// (`TypeIIIAudioNarration`), made only when `fetchNarration` is given, for those two sites' post addresses.
    public static func find(
        sharedURL: URL,
        articleURL: String,
        itemId: String,
        fetched: FetchedPageMemo?,
        fetchPage: FetchPage,
        fetchNarration: TypeIIIAudioNarration.Fetch? = nil
    ) async -> Outcome {
        let candidates = [sharedURL, URL(string: articleURL)].compactMap { $0 }
        if let narrated = candidates.first(where: { TypeIIIAudioNarration.postURL(for: $0) != nil }) {
            guard let fetchNarration else { return .notSubstack }
            switch await TypeIIIAudioNarration.find(url: narrated, itemId: itemId, fetch: fetchNarration) {
            case .notCovered: return .notSubstack
            case .failed(let reason): return .failed(reason)
            case .noNarration(let reason): return .noVoiceover(reason: reason)
            case .found(let audio): return .found(audio)
            }
        }
        let remembered = candidates.lazy.compactMap { url in
            fetched?.page(for: url).flatMap { page in
                PublisherNarrationEvidence.mayHaveVoiceover(url) || PublisherNarrationEvidence.declaresPreloads(page.data) ? page : nil
            }
        }.first
        let html: String
        let finalURL: URL
        if let page = remembered {
            guard page.finalURL.scheme?.lowercased() == "https" else { return .failed(URLError(.secureConnectionFailed).localizedDescription) }
            guard page.data.count <= maximumPageBytes else { return .failed(URLError(.dataLengthExceedsMaximum).localizedDescription) }
            (html, finalURL) = (String(decoding: page.data, as: UTF8.self), page.finalURL)
        } else {
            guard let pageURL = candidates.first(where: PublisherNarrationEvidence.mayHaveVoiceover) else { return .notSubstack }
            do {
                (html, finalURL) = try await fetchPage(pageURL)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        guard let audio = PublisherNarrationEvidence.publisherAudio(postPage: html, finalURL: finalURL, itemId: itemId) else {
            return .noVoiceover(reason: PublisherNarrationEvidence.absence(postPage: html, finalURL: finalURL))
        }
        return .found(audio)
    }
}

/// Which posts have had their voiceover looked up in this launch, and when a post may be looked up again (#3297).
/// An answer of "no recording" is final for the launch, so opening the item can't repeat a page fetch. An answer of
/// "not yet" (Substack's narration was `pending` or `processing` when the page was read) and a failed try are not:
/// the next open or play looks again. A "not yet" answer waits `retryInterval` first and stops after
/// `maximumNotYetTries`, so a post that never finishes isn't fetched on every open. Every lookup is still the
/// listener's own action (open or play), never a background fetch (owner's call, 2026-10-21).
public struct VoiceoverLookupLedger: Sendable {
    public static let retryInterval: TimeInterval = 60
    public static let maximumNotYetTries = 5

    private var settled = Set<String>()
    private var retryNotBefore: [String: Date] = [:]
    private var notYetTries: [String: Int] = [:]

    public init() {}

    /// True for an item not looked up in this launch, or whose last answer was "not yet" or a failure and whose
    /// wait is over.
    public func mayLookUp(itemId: String, now: Date = Date()) -> Bool {
        guard !settled.contains(itemId) else { return false }
        return retryNotBefore[itemId].map { now >= $0 } ?? true
    }

    /// Marks the item as being looked up and says whether this caller may start the lookup. Claiming at once, not
    /// inside the lookup task, keeps two callers to one page fetch.
    public mutating func claim(itemId: String, now: Date = Date()) -> Bool {
        guard mayLookUp(itemId: itemId, now: now) else { return false }
        settled.insert(itemId)
        retryNotBefore[itemId] = nil
        return true
    }

    private static func isNotYet(reason: String) -> Bool {
        PublisherNarrationEvidence.isNotYet(absence: reason) || TypeIIIAudioNarration.isNotYet(reason: reason)
    }

    /// Takes a lookup's status (`SharedLinkVoiceover.remember`'s report): `failed:` lets the next open try at once
    /// and `none:<reason>` for a "not yet" reason lets it try after the wait; anything else stays settled.
    public mutating func record(status: String, itemId: String, now: Date = Date()) {
        if status.hasPrefix("failed:") {
            settled.remove(itemId)
        } else if status.hasPrefix("none:"), Self.isNotYet(reason: String(status.dropFirst("none:".count))) {
            let tries = (notYetTries[itemId] ?? 0) + 1
            notYetTries[itemId] = tries
            guard tries < Self.maximumNotYetTries else { return }
            settled.remove(itemId)
            retryNotBefore[itemId] = now.addingTimeInterval(Self.retryInterval)
        }
    }
}

/// The latest voiceover outcome of each recently shared post, newest last (#810). A single diagnostic line kept
/// only the last share, so a later link (an openai.com page, `not_substack`) hid what happened to the post the
/// listener asked about.
public struct SharedPostVoiceoverLog: Sendable {
    public static let capacity = 8

    private var entries: [(itemId: String, status: String)] = []

    public init() {}

    /// Keeps `status` as `itemId`'s latest and moves that item to the end. The oldest item drops off past `capacity`.
    public mutating func record(_ status: String, for itemId: String) {
        entries.removeAll { $0.itemId == itemId }
        entries.append((itemId, status))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// One line per item, `<itemId>: <status>`, joined by `"; "`, newest last.
    public var summary: String {
        entries.map { "\($0.itemId): \($0.status)" }.joined(separator: "; ")
    }
}

/// Failures that say only "no usable connection right now", so a try that hit one is tried again later and is
/// never recorded as the recording's verdict (#810: clipping works offline, the voiceover waits for a network).
public enum OfflineFailure {
    public static func isConnectivity(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}
