// The daily Substack format canary (#2027). For each feed it follows the feed the way the app does
// (`FollowedSourceCoordinator`), takes the newest posts, reads each post page once for a raw look and runs
// the app's parser (`PublisherNarrationEvidence`) on it, and runs the app's own lookup (`publisherAudioEntry`).
// It stops a feed at the first post that gives a voice. See `SubstackCanary` for the verdict rules.
//
//   swift run substack-canary [--report <file.md>] [--posts <n>] [--feed <https feed URL> ...]
//
// Exit status: 0 passed, 1 a parser failure, 3 inconclusive (feeds couldn't be read), 2 bad arguments.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionKit
import SessionKitFeeds
import SubstackCanaryCore

/// Three shapes: a substack.com subdomain with Substack's automatic voice, a custom domain with the automatic
/// voice and many paid posts, and a custom domain whose author records a voiceover.
let defaultFeeds = [
    "https://thezvi.substack.com/feed",
    "https://www.noahpinion.blog/feed",
    "https://www.experimental-history.com/feed",
]

var feeds: [String] = []
var reportPath: String?
var postsPerFeed = 4
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--report": reportPath = arguments.next()
    case "--posts": postsPerFeed = arguments.next().flatMap { Int($0) } ?? postsPerFeed
    case "--feed": if let feed = arguments.next() { feeds.append(feed) }
    default:
        FileHandle.standardError.write(Data("Unknown argument \(argument)\n".utf8))
        exit(2)
    }
}
if feeds.isEmpty { feeds = defaultFeeds }

/// The app's post-page request (`FollowedSourceCoordinator.loadHTML` and its default session): ephemeral, no
/// cache, the same Accept header and timeouts, and the same 1 MB cap.
let pageSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 30
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
}()
let appPageLimit = 1 * 1_024 * 1_024

enum PageResult {
    case page(String)
    case tooLarge(Int)
    case failed(String)
}

func fetchPage(_ url: URL) async -> PageResult {
    var request = URLRequest(url: url)
    request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
    do {
        let (data, response) = try await pageSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .failed("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else { return .failed("HTTP \(http.statusCode)") }
        guard data.count <= appPageLimit else { return .tooLarge(data.count) }
        return .page(String(decoding: data, as: UTF8.self))
    } catch {
        return .failed((error as? URLError).map { "URL error \($0.code.rawValue)" } ?? String(describing: error))
    }
}

/// One retry for a network error, then "could not check".
func fetchPageRetryingOnce(_ url: URL) async -> PageResult {
    let first = await fetchPage(url)
    guard case .failed = first else { return first }
    try? await Task.sleep(nanoseconds: 5_000_000_000)
    return await fetchPage(url)
}

func voiceKind(_ entry: FeedEntry) -> String? {
    guard entry.publisherNarrationConfirmed == true else { return nil }
    return entry.publisherNarrationGenerated == true ? "generated_voice" : "voiceover"
}

func label(_ verdict: SubstackCanary.PostVerdict) -> String {
    switch verdict {
    case .voice(let kind): "VOICE: \(kind)"
    case .noneOffered(let why): "none offered: \(why)"
    case .parserMissed(let why): "FAIL, parser missed: \(why)"
    case .appDropped(let why): "FAIL, app dropped: \(why)"
    case .couldNotCheck(let why): "could not check: \(why)"
    }
}

func label(_ verdict: SubstackCanary.FeedVerdict) -> String {
    switch verdict {
    case .voice: "pass (a voice found)"
    case .noneOffered: "pass (pages say no voice)"
    case .failed: "FAIL"
    case .couldNotCheck: "could not check"
    }
}

var lines: [String] = []
var feedVerdicts: [SubstackCanary.FeedVerdict] = []
for feed in feeds {
    let repository = InMemorySessionRepository()
    let coordinator = FollowedSourceCoordinator(repository: repository, signals: nil)
    var subscription: FeedSubscription?
    var feedError = ""
    for attempt in 0..<2 where subscription == nil {
        if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        do { subscription = try await coordinator.followFeed(urlString: feed) } catch { feedError = String(describing: error) }
    }
    guard let subscription,
          let entries = try? repository.loadFeedEntries(subscriptionId: subscription.id) else {
        lines.append("- **\(feed)**: could not check (the feed didn't load twice: \(feedError))")
        feedVerdicts.append(.couldNotCheck)
        continue
    }
    let newest = entries.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.prefix(postsPerFeed)
    var posts: [(FeedEntry, SubstackCanary.PostVerdict)] = []
    for entry in newest {
        guard let url = URL(string: entry.canonicalURL) else {
            posts.append((entry, .couldNotCheck("the entry has no usable address")))
            continue
        }
        let verdict: SubstackCanary.PostVerdict
        switch await fetchPageRetryingOnce(url) {
        case .failed(let why):
            verdict = .couldNotCheck("the page didn't load twice (\(why))")
        case .tooLarge(let bytes):
            verdict = .appDropped("the page is \(bytes) bytes, over the app's 1 MB limit, so the app never reads it")
        case .page(let html):
            let parsed = PublisherNarrationEvidence.voiceover(inPostPage: html).map { _ in "voiceover" }
                ?? PublisherNarrationEvidence.generatedVoice(inPostPage: html).map { _ in "generated_voice" }
            var appVoice = voiceKind(await coordinator.publisherAudioEntry(for: entry, trigger: .formatCheck))
            // The lookup fetches the page itself; give a network blip there the same one retry.
            if appVoice == nil, parsed != nil { appVoice = voiceKind(await coordinator.publisherAudioEntry(for: entry, trigger: .formatCheck)) }
            let reading = SubstackCanary.AppReading(
                parserVoice: parsed,
                absence: PublisherNarrationEvidence.absence(inPostPage: html),
                appVoice: appVoice,
                bodyWordCount: entry.bodyWordCount,
                publisherPlatform: entry.publisherPlatform
            )
            verdict = SubstackCanary.verdict(raw: SubstackCanary.RawPage(html: html), app: reading,
                                             minimumBodyWords: PublisherAudioDetector.minimumBodyWords)
        }
        posts.append((entry, verdict))
        if case .voice = verdict { break }
    }
    let feedVerdict = SubstackCanary.feedVerdict(posts.map(\.1))
    feedVerdicts.append(feedVerdict)
    lines.append("- **\(feed)**: \(label(feedVerdict))")
    for (entry, verdict) in posts {
        lines.append("  - [\(entry.title)](\(entry.canonicalURL)): \(label(verdict))")
    }
}

let status = SubstackCanary.exitStatus(feedVerdicts)
let headline = switch status {
case 0: "Substack canary passed: the app's parser read every feed it could reach."
case 1: "Substack canary FAILED: the app's parser missed a publisher voice, or found none on any feed."
default: "Substack canary inconclusive: no voice found and at least one feed couldn't be read."
}
let report = ([headline, ""] + lines).joined(separator: "\n") + "\n"
print(report, terminator: "")
if let reportPath {
    do { try report.write(toFile: reportPath, atomically: true, encoding: .utf8) } catch {
        FileHandle.standardError.write(Data("Couldn't write the report: \(error)\n".utf8))
    }
}
exit(status)
