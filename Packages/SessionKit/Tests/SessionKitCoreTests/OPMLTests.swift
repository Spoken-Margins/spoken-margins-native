import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

final class OPMLTests: XCTestCase {
    func testExportsFromFourAppsParseToTheirFeedsAndSkipOvercastEpisodes() throws {
        let expected: [(file: String, title: String, feeds: [String])] = [
            ("overcast", "Overcast Podcast Subscriptions", ["The Daily", "Radiolab", "Hard Fork"]),
            ("pocket-casts", "Pocket Casts Feeds", ["The Daily", "Stuff You Should Know", "Science Vs", "Hidden Brain"]),
            ("castro", "Castro Subscriptions", ["99% Invisible", "Radiolab", "Darknet Diaries"]),
            ("antennapod", "AntennaPod Subscriptions", ["In Our Time", "Philosophize This!", "The Daily"]),
        ]
        for app in expected {
            let document = try OPMLParser.parse(Self.fixture(app.file))
            XCTAssertEqual(document.title, app.title, app.file)
            XCTAssertEqual(document.feeds.map(\.title), app.feeds, app.file)
            XCTAssertTrue(document.feeds.allSatisfy { $0.feedURL.hasPrefix("https://") }, app.file)
            XCTAssertEqual(document.unusableOutlineCount, 0, app.file)
        }
    }

    func testPreviewSkipsFeedsAlreadyFollowedAndListsTheRest() throws {
        let existing = [Self.subscription("The Daily", "https://feeds.simplecast.com/Sl5CSM3S"),
                        Self.subscription("Radiolab", "http://feeds.simplecast.com/EmVW7VGp/")]
        let preview = OPMLImportPlanner.preview(try OPMLParser.parse(Self.fixture("overcast")), existing: existing)
        XCTAssertEqual(preview.toFollow.map(\.title), ["Hard Fork"])
        XCTAssertEqual(preview.alreadyFollowed.map(\.title), ["The Daily", "Radiolab"], "http vs https and a trailing slash are the same feed")
        XCTAssertTrue(preview.duplicatesInFile.isEmpty)
        let candidate = try XCTUnwrap(preview.toFollow.first)
        XCTAssertEqual(candidate.resolverId, "opml")
        XCTAssertEqual(candidate.confidence, .exact)
        XCTAssertTrue(candidate.isFollowable)
    }

    func testEdgeCasesFoldersHTTPPrivateDuplicatesEscapesAndUnusableOutlines() throws {
        let document = try OPMLParser.parse(Self.fixture("edge-cases"))
        XCTAssertEqual(document.title, "Mixed & Messy")
        XCTAssertEqual(document.unusableOutlineCount, 2, "no URL, and an ftp URL")
        XCTAssertEqual(document.feeds.first { $0.title == "Accidental Tech Podcast" }?.folders, ["Tech"], "lowercase xmlurl is read")
        XCTAssertEqual(document.feeds.first { $0.title == "Hello Internet" }?.folders, ["Tech", "Nested"])
        XCTAssertEqual(document.feeds.first { $0.title == "Science & Society" }?.feedURL, "https://example.org/science&society.xml")
        XCTAssertFalse(document.feeds.contains { $0.title == "A bookmark" })

        let preview = OPMLImportPlanner.preview(document, existing: [])
        XCTAssertEqual(preview.duplicatesInFile.map(\.title), ["The Daily"], "host case and a trailing slash don't make a new feed")
        let hello = try XCTUnwrap(preview.toFollow.first { $0.title == "Hello Internet" })
        XCTAssertEqual(hello.feed?.url, "https://www.hellointernet.fm/podcast?format=rss")
        XCTAssertTrue(hello.reason.contains("https"))
        XCTAssertEqual(hello.confidence, .likely, "an http feed rewritten to https is a guess, not the feed itself")
        let patron = try XCTUnwrap(preview.toFollow.first { $0.title == "Patron Feed" })
        XCTAssertEqual(patron.feed?.isPrivate, true, "a private feed can be followed but stays on the device")
    }

    func testHostileAndWrongFilesFailClosed() throws {
        // The guard that holds on every platform: parse's parser is configured never to
        // resolve external entities. Flipping either setting fails here.
        let configured = OPMLParser.makeXMLParser(Data())
        XCTAssertFalse(configured.shouldResolveExternalEntities)
        XCTAssertEqual(configured.externalEntityResolvingPolicy, .never)

        // Behavioral check. It can only catch a regression where the platform parser would
        // substitute the entity; Apple's XMLParser never does, so on Apple platforms the
        // settings check above is what guards this.
        let marker = "ENTITY-MARKER-\(UUID().uuidString)"
        let secretFile = FileManager.default.temporaryDirectory.appendingPathComponent("opml-entity-\(UUID().uuidString).txt")
        try marker.write(to: secretFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secretFile) }
        let entity = Data("""
        <?xml version="1.0"?>
        <!DOCTYPE opml [<!ENTITY secret SYSTEM "\(secretFile.absoluteString)">]>
        <opml version="2.0"><head><title>&secret;</title></head><body><outline type="rss" text="Feed" xmlUrl="https://example.com/feed.xml"/></body></opml>
        """.utf8)
        if let document = try? OPMLParser.parse(entity) {
            XCTAssertFalse(document.title?.contains(marker) ?? false, "external entities are never resolved")
        }

        let deep = Data(("<opml><body>" + String(repeating: "<outline text=\"x\">", count: 40) + String(repeating: "</outline>", count: 40) + "</body></opml>").utf8)
        XCTAssertThrowsError(try OPMLParser.parse(deep)) { XCTAssertEqual($0 as? OPMLError, .tooDeep) }

        let many = Data(("<opml><body>" + String(repeating: "<outline type=\"rss\" text=\"x\" xmlUrl=\"https://example.com/f\"/>", count: 11) + "</body></opml>").utf8)
        XCTAssertThrowsError(try OPMLParser.parse(many, limits: OPMLLimits(maximumOutlines: 10))) { XCTAssertEqual($0 as? OPMLError, .tooManyOutlines) }
        XCTAssertThrowsError(try OPMLParser.parse(Data(repeating: 0x20, count: 11), limits: OPMLLimits(maximumBytes: 10))) { XCTAssertEqual($0 as? OPMLError, .tooLarge) }

        let rss = Data(#"<?xml version="1.0"?><rss version="2.0"><channel><title>A feed</title></channel></rss>"#.utf8)
        XCTAssertThrowsError(try OPMLParser.parse(rss)) { XCTAssertEqual($0 as? OPMLError, .notOPML) }
        XCTAssertThrowsError(try OPMLParser.parse(Data("<opml><body><outline".utf8)))
    }

    func testExportRoundTripsAndWithholdsPrivateFeeds() throws {
        let subscriptions = [
            Self.subscription("Tom & Jerry's \"Show\" <live>", "https://example.com/feed.xml?a=1&b=2"),
            Self.subscription("The Daily", "https://feeds.simplecast.com/Sl5CSM3S"),
            Self.subscription("Patron Feed", "https://www.patreon.com/rss/exampleshow?auth=Zx81kq0P2mNw7rT4yB6vC9dF3hJ5lA1s"),
        ]
        let export = OPMLExporter.export(subscriptions, createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(export.exportedCount, 2)
        XCTAssertEqual(export.withheldPrivateCount, 1)
        let text = String(decoding: export.data, as: UTF8.self)
        XCTAssertFalse(text.contains("patreon"), "a private feed never leaves the device (#168)")
        XCTAssertTrue(text.contains("Thu, 01 Jan 1970 00:00:00 GMT"))

        let reparsed = try OPMLParser.parse(export.data)
        XCTAssertEqual(Set(reparsed.feeds.map(\.feedURL)), ["https://example.com/feed.xml?a=1&b=2", "https://feeds.simplecast.com/Sl5CSM3S"])
        XCTAssertTrue(reparsed.feeds.contains { $0.title == "Tom & Jerry's \"Show\" <live>" })

        let again = OPMLImportPlanner.preview(reparsed, existing: subscriptions)
        XCTAssertTrue(again.toFollow.isEmpty, "importing our own export changes nothing")
        XCTAssertEqual(again.alreadyFollowed.count, 2)
    }

    func testImportFollowsOnlyTickedFeedsInFileOrderAndKeepsGoingAfterAFailure() async throws {
        let preview = OPMLImportPlanner.preview(try OPMLParser.parse(Self.fixture("pocket-casts")), existing: [])
        XCTAssertEqual(preview.toFollow.map(\.title), ["The Daily", "Stuff You Should Know", "Science Vs", "Hidden Brain"])
        struct Unreachable: Error {}
        var attempts: [String] = []
        var steps: [Int] = []
        let result = await OPMLImportRunner.follow(
            preview,
            selected: Set(preview.toFollow.filter { $0.title != "Science Vs" }.map(\.id)),
            describe: { _ in "The source did not return a supported feed." },
            progress: { done, _ in steps.append(done) }
        ) { candidate in
            attempts.append(candidate.title)
            if candidate.title == "Stuff You Should Know" { throw Unreachable() }
        }
        XCTAssertEqual(attempts, ["The Daily", "Stuff You Should Know", "Hidden Brain"], "one at a time, in file order, unticked skipped")
        XCTAssertEqual(result.followed.map(\.title), ["The Daily", "Hidden Brain"])
        XCTAssertEqual(result.failed.map(\.candidate.title), ["Stuff You Should Know"])
        XCTAssertEqual(result.failed.first?.reason, "The source did not return a supported feed.")
        XCTAssertTrue(result.notTried.isEmpty)
        XCTAssertEqual(steps, [0, 1, 2, 3])
    }

    func testImportWithNothingTickedFollowsNothing() async throws {
        let preview = OPMLImportPlanner.preview(try OPMLParser.parse(Self.fixture("castro")), existing: [])
        var attempts = 0
        let result = await OPMLImportRunner.follow(preview, selected: []) { _ in attempts += 1 }
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(result, OPMLImportResult())
    }

    func testCancelledImportStopsBeforeTheNextFeedAndListsWhatWasNotTried() async throws {
        let preview = OPMLImportPlanner.preview(try OPMLParser.parse(Self.fixture("castro")), existing: [])
        let task = Task { () -> (OPMLImportResult, [String]) in
            var attempts: [String] = []
            let result = await OPMLImportRunner.follow(preview, selected: Set(preview.toFollow.map(\.id))) { candidate in
                attempts.append(candidate.title)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return (result, attempts)
        }
        let (result, attempts) = await task.value
        XCTAssertEqual(attempts, ["99% Invisible"])
        XCTAssertEqual(result.followed.map(\.title), ["99% Invisible"])
        XCTAssertEqual(result.notTried.map(\.title), ["Radiolab", "Darknet Diaries"])
    }

    func testStoppingDuringAFollowListsThatFeedAsNotTriedRatherThanFailed() async throws {
        let preview = OPMLImportPlanner.preview(try OPMLParser.parse(Self.fixture("castro")), existing: [])
        let task = Task { () -> OPMLImportResult in
            await OPMLImportRunner.follow(preview, selected: Set(preview.toFollow.map(\.id))) { candidate in
                guard candidate.title == "Radiolab" else { return }
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
        }
        let result = await task.value
        XCTAssertEqual(result.followed.map(\.title), ["99% Invisible"])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.notTried.map(\.title), ["Radiolab", "Darknet Diaries"])
    }

    private static func subscription(_ title: String, _ url: String) -> FeedSubscription {
        let host = URLComponents(string: url)?.host ?? "unknown"
        return FeedSubscription(id: "subscription-\(title)", source: SourceIdentity(id: "source-\(title)", kind: .podcastFeed, canonicalURL: url, host: host, title: title))
    }

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: SourceCatalogTests.path("Contracts/fixtures/opml/\(name).opml"))
    }
}
