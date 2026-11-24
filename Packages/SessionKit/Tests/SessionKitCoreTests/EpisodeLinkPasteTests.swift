import Foundation
import XCTest
@testable import SessionKit

final class EpisodeLinkPasteTests: XCTestCase {
    func testReadsTheRequestedLineForm() throws {
        let entry = try XCTUnwrap(EpisodeLinkPaste.entry(fromLine:
            "1. **Tradeoffs — How Do We Keep the Nursing Shortage From Getting Worse?** | 32 min | clean | 08:15 | https://podcasts.apple.com/us/podcast/x/id1480845603?i=1000537077641"))
        XCTAssertEqual(entry.claimedShow, "Tradeoffs")
        XCTAssertEqual(entry.claimedTitle, "How Do We Keep the Nursing Shortage From Getting Worse?")
        XCTAssertEqual(entry.kind, .appleEpisode)
        XCTAssertFalse(entry.markedShowLink)
        XCTAssertEqual(entry.url, "https://podcasts.apple.com/us/podcast/x/id1480845603?i=1000537077641")
    }

    func testLineVariantsAssistantsWrite() throws {
        // (line, url, show, title, marked show link)
        let rows: [(String, String, String?, String?, Bool)] = [
            ("- Show – Title | 30 min | https://example.com/a.", "https://example.com/a", "Show", "Title", false),
            ("Show - Title | [link](https://example.com/b)", "https://example.com/b", "Show", "Title", false),
            ("Show: Title | 20m | (show link) https://podcasts.apple.com/us/podcast/s/id1", "https://podcasts.apple.com/us/podcast/s/id1", "Show", "Title", true),
            ("  Just a title | https://example.com/c)  ", "https://example.com/c", nil, "Just a title", false),
            ("https://example.com/d", "https://example.com/d", nil, nil, false),
            ("Wiki — A (B) | https://en.wikipedia.org/wiki/A_(B)", "https://en.wikipedia.org/wiki/A_(B)", "Wiki", "A (B)", false),
            ("Show — “Quoted” | <https://example.com/e>", "https://example.com/e", "Show", "Quoted", false),
        ]
        for (line, url, show, title, marked) in rows {
            let entry = try XCTUnwrap(EpisodeLinkPaste.entry(fromLine: line), line)
            XCTAssertEqual(entry.url, url, line)
            XCTAssertEqual(entry.claimedShow, show, line)
            XCTAssertEqual(entry.claimedTitle, title, line)
            XCTAssertEqual(entry.markedShowLink, marked, line)
        }
        XCTAssertNil(EpisodeLinkPaste.entry(fromLine: "No link here, just prose."))
        XCTAssertNil(EpisodeLinkPaste.entry(fromLine: ""))
        XCTAssertEqual(EpisodeLinkPaste.entries(in: "Intro\nA — B | https://x.com/1\n\nC — D | https://x.com/2\nOutro").count, 2)
        // A sources list after the picks is not more picks; with no formed lines, every linked line counts.
        let withSources = "A — B | 30 min | https://x.com/1\nC — D | 20 min | https://x.com/2\n\nSources:\n- [Page](https://x.com/3)\n- https://x.com/4"
        XCTAssertEqual(EpisodeLinkPaste.entries(in: withSources).map(\.url), ["https://x.com/1", "https://x.com/2"])
        XCTAssertEqual(EpisodeLinkPaste.entries(in: "A — B https://x.com/1\nC — D https://x.com/2").count, 2)
    }

    func testLinkKinds() {
        let rows: [(String, EpisodeLinkPaste.LinkKind)] = [
            ("https://podcasts.apple.com/us/podcast/t/id1?i=100", .appleEpisode),
            ("https://podcasts.apple.com/us/podcast/t/id1", .appleShow),
            ("https://podcasts.apple.com/us/podcast/t/id1?i=", .appleShow),
            ("https://open.spotify.com/episode/abc", .spotify),
            ("https://spotify.link/abc", .spotify),
            ("https://www.youtube.com/watch?v=abc", .youtube),
            ("https://youtu.be/abc", .youtube),
            ("https://music.youtube.com/watch?v=abc", .youtube),
            ("https://writer.substack.com/p/post", .substack),
            ("https://notyoutube.com/x", .other),
            ("https://tradeoffs.org/?p=1", .other),
            ("not a url", .other),
        ]
        for (url, kind) in rows { XCTAssertEqual(EpisodeLinkPaste.kind(of: url), kind, url) }
    }

    func testTitleMatchingNeighbours() {
        let base = "How Do We Keep the Nursing Shortage From Getting Worse?"
        let same = [
            "how do we keep the nursing shortage from getting worse",
            "  How  Do We Keep The Nursing Shortage From Getting Worse!  ",
            "Ep. 112: How Do We Keep the Nursing Shortage From Getting Worse?",
            "How Do We Keep the Nursing Shortage from Getting Worse? (Rebroadcast)",
            "How do we keep the nursing shortage from getting worse — Tradeoffs",
        ]
        for title in same { XCTAssertTrue(EpisodeLinkPaste.titlesMatch(base, title), title) }
        XCTAssertTrue(EpisodeLinkPaste.titlesMatch("Café Society & Jazz", "Cafe Society and Jazz"))
        XCTAssertTrue(EpisodeLinkPaste.titlesMatch("Don’t Panic", "Don't Panic"))
        XCTAssertTrue(EpisodeLinkPaste.titlesMatch("Ｗｉｄｅ Ｔｉｔｌｅ", "Wide Title"))

        let different = [
            "Why Hospitals Are Closing Maternity Wards",
            "The Nursing Home Problem",
            "Worse",
            "",
            "   ",
            String(repeating: "lorem ipsum ", count: 200),
        ]
        for title in different { XCTAssertFalse(EpisodeLinkPaste.titlesMatch(base, title), title) }
        // One-word titles must match exactly, not as a substring of a longer title.
        XCTAssertFalse(EpisodeLinkPaste.titlesMatch("Bail", "Bailout Nation"))
        XCTAssertTrue(EpisodeLinkPaste.titlesMatch("Bail", "bail"))
        // Part 1 and Part 2 of a series are different episodes only if the words say so; numbers count.
        XCTAssertFalse(EpisodeLinkPaste.titlesMatch("Bridges 1", "Dams 2"))
    }

    func testVerdicts() throws {
        let entry = try XCTUnwrap(EpisodeLinkPaste.entry(fromLine: "Show — The Right One | https://podcasts.apple.com/us/podcast/s/id1?i=2"))
        func result(_ status: LinkResolutionStatus, title: String?) -> LinkResolutionResult {
            LinkResolutionResult(
                requestId: "r",
                status: status,
                originalLink: SourceLink(url: entry.url, provider: "apple_podcasts", title: nil, role: "episode_page"),
                selectedCandidate: title.map {
                    LinkResolutionCandidate(sourceLink: SourceLink(url: entry.url, provider: "apple_podcasts", title: $0, role: "episode_page"),
                                            title: $0, audioURL: "https://cdn.example/a.mp3", confidence: 1)
                },
                failureReason: status == .playable ? nil : "apple_lookup_empty"
            )
        }
        XCTAssertEqual(EpisodeLinkPaste.verdict(for: entry, result: result(.playable, title: "The Right One")), .rightEpisode)
        XCTAssertEqual(EpisodeLinkPaste.verdict(for: entry, result: result(.playable, title: "Something Else Entirely")), .wrongEpisode)
        XCTAssertEqual(EpisodeLinkPaste.verdict(for: entry, result: result(.needsReview, title: nil)), .failed)
        XCTAssertEqual(EpisodeLinkPaste.verdict(for: entry, result: result(.playable, title: nil)), .failed)
        var audioFile = result(.playable, title: "0b7c3d2c c5fa 4d7c")
        audioFile.selectedCandidate?.sourceLink.provider = "direct_audio"
        XCTAssertEqual(EpisodeLinkPaste.verdict(for: entry, result: audioFile), .unchecked, "a file name is not a title")
        var untitled = entry
        untitled.claimedTitle = nil
        XCTAssertEqual(EpisodeLinkPaste.verdict(for: untitled, result: result(.playable, title: "Anything")), .unchecked)
    }
    // MARK: Shared fixtures (#5270)

    /// `Contracts/fixtures/find-something/`, which the quiz page's `parsePaste` and `titlesMatch` (Site/quiz/quiz.js)
    /// also run, so the two ports can't drift.
    private var sharedFixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contracts/fixtures/find-something")
    }

    private struct PasteFixture: Decodable {
        var text: String
        var expected: [EpisodeLinkPaste.Entry]
    }

    private struct TitleMatchFixture: Decodable {
        struct Case: Decodable { var a: String; var b: String; var match: Bool }
        var cases: [Case]
    }

    func testEveryPasteFixtureReadsToItsExpectedEntries() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: sharedFixtures.path)
            .filter { $0.hasPrefix("paste-") && $0.hasSuffix(".json") }.sorted()
        XCTAssertGreaterThanOrEqual(names.count, 5, "the paste fixtures are missing")
        for name in names {
            let fixture = try JSONDecoder().decode(PasteFixture.self, from: Data(contentsOf: sharedFixtures.appendingPathComponent(name)))
            XCTAssertEqual(EpisodeLinkPaste.entries(in: fixture.text), fixture.expected, name)
        }
    }

    func testEveryTitlePairInTheSharedTable() throws {
        let table = try JSONDecoder().decode(TitleMatchFixture.self, from: Data(contentsOf: sharedFixtures.appendingPathComponent("title-match.json")))
        XCTAssertGreaterThanOrEqual(table.cases.count, 20)
        for pair in table.cases {
            XCTAssertEqual(EpisodeLinkPaste.titlesMatch(pair.a, pair.b), pair.match, "\(pair.a) / \(pair.b)")
            XCTAssertEqual(EpisodeLinkPaste.titlesMatch(pair.b, pair.a), pair.match, "reversed: \(pair.a) / \(pair.b)")
        }
    }
}
