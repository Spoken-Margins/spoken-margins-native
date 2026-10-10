import Foundation

/// What a podcast-name search found, for the first-run drawer's search field (#471).
public enum PodcastNameSearchOutcome: Equatable, Sendable {
    /// The shows Apple's search returned, best first. Shows with no public feed are included, with
    /// `feed == nil` and the reason in `reason`, so the listener learns why they can't be followed.
    case results([SourceCandidate])
    /// The search couldn't be completed. The text is for the listener.
    case failed(String)
}

/// Searches podcasts by name for the drawer's search field: waits for the listener to pause typing,
/// keeps one request in flight, and drops an answer that a newer search has made stale.
///
/// A newer `search` call supersedes every older one, whether the older one is still waiting out the
/// pause or already has a request out; superseded calls return nil, so a slow answer for "hard"
/// can never replace the answer for "hard fork".
public actor PodcastNameSearch {
    public static let minimumQueryLength = 2
    public static let defaultPause: Duration = .milliseconds(300)
    public static let networkFailureMessage = "Search isn't available right now. Check your connection and try again."

    private let resolver: ITunesSearchSourceResolver
    private let pause: Duration
    private var latest = 0

    public init(resolver: ITunesSearchSourceResolver, pause: Duration = PodcastNameSearch.defaultPause) {
        self.resolver = resolver
        self.pause = pause
    }

    /// Whether `query` is long enough to search for, after trimming.
    public static func isSearchable(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumQueryLength
    }

    /// The outcome for `query`, or nil when a newer search (or `cancel`) replaced this one first or
    /// the query is too short to search.
    public func search(_ query: String) async -> PodcastNameSearchOutcome? {
        latest += 1
        let generation = latest
        guard Self.isSearchable(query) else { return nil }
        do {
            try await Task.sleep(for: pause)
        } catch {
            return nil
        }
        guard generation == latest else { return nil }
        let outcome: PodcastNameSearchOutcome
        do {
            outcome = .results(try await resolver.resolve(.query(query)))
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            outcome = .failed(Self.networkFailureMessage)
        }
        return generation == latest ? outcome : nil
    }

    /// Supersedes any search that is waiting or in flight, for example when the field is cleared.
    public func cancel() {
        latest += 1
    }
}
