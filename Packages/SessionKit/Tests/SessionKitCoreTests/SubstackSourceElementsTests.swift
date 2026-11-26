import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2032: a Substack import used to drop its pictures and the addresses of its links and embeds, so Timeline (#1624)
/// had nothing to draw. The page below is what the bundled extractor produces for a Substack post (a captioned
/// picture, inline links, a video player, a picture with no caption), kept as Markdown.
/// Layer that should have caught it: a host test on `ObsidianMarkdownParser`, which had no case for pictures or links.
final class SubstackSourceElementsTests: XCTestCase {
    private let sourceURL = "https://example.substack.com/p/rates"

    private func prose(_ word: String) -> String {
        Array(repeating: "\(word) words fill this paragraph so it reads like an article.", count: 3).joined(separator: " ")
    }

    private var page: String {
        """
        # Rates

        \(prose("First"))

        ![A chart of rates](https://substackcdn.com/image/a.jpg)

        Rates since 2020. Source: the Fed.

        See [the study](https://example.com/study) and [this **thread**](https://other.org/x). Also [the study again](https://example.com/study).

        ![](https://www.youtube.com/watch?v=abc123)

        \(prose("Second"))

        ![](https://substackcdn.com/image/b.jpg)

        \(prose("Third"))
        """
    }

    private func parse(_ markdown: String, sourceURL: String? = nil) throws -> ParsedObsidianMarkdown {
        try ObsidianMarkdownParser.parse(fileName: "Rates", contents: markdown, fallbackTitle: "Rates", sourceURL: sourceURL ?? self.sourceURL)
    }

    private func start(of snippet: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: snippet), "\(snippet) is not in the text")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    func testCapturesPicturesEmbedsAndLinksAtTheirPlaceInTheText() throws {
        let parsed = try parse(page)
        let text = parsed.text
        let elements = parsed.elements

        let chart = try XCTUnwrap(elements.first { $0.url == "https://substackcdn.com/image/a.jpg" })
        XCTAssertEqual(chart.kind, .picture)
        XCTAssertEqual(chart.label, "Rates since 2020. Source: the Fed.", "the paragraph after a picture is its caption")
        XCTAssertEqual(chart.altText, "A chart of rates")
        XCTAssertEqual(chart.start, try start(of: "Rates since 2020", in: text))

        let video = try XCTUnwrap(elements.first { $0.kind == .embed })
        XCTAssertEqual(video.label, "YouTube video")
        XCTAssertEqual(video.url, "https://www.youtube.com/watch?v=abc123")
        XCTAssertEqual(video.start, try start(of: "Second words", in: text), "an embed sits where the next passage begins")

        let bare = try XCTUnwrap(elements.first { $0.url == "https://substackcdn.com/image/b.jpg" })
        XCTAssertEqual(bare.label, "Picture", "a picture with no caption or alt text is just a picture")
        XCTAssertNil(bare.altText)
        XCTAssertEqual(bare.start, try start(of: "Third words", in: text))

        let study = try XCTUnwrap(elements.first { $0.url == "https://example.com/study" })
        XCTAssertEqual(study.kind, .link)
        XCTAssertEqual(study.label, "the study")
        XCTAssertEqual(study.start, try start(of: "the study and", in: text), "a link sits on its own words")
        let thread = try XCTUnwrap(elements.first { $0.url == "https://other.org/x" })
        XCTAssertEqual(thread.label, "this thread", "the page's bold markers are not part of the row")
        XCTAssertEqual(thread.start, try start(of: "this thread", in: text))

        XCTAssertEqual(elements.filter { $0.url == "https://example.com/study" }.count, 1, "one row per address")
        XCTAssertEqual(elements.map(\.start), elements.map(\.start).sorted(), "in text order")
        XCTAssertEqual(elements.map(\.id), (0..<elements.count).map { String(format: "e%05d", $0) }, "ids sort in text order")
    }

    func testTheTextAndItsChaptersAreExactlyWhatTheyWereWithoutElements() throws {
        let withElements = try parse(page)
        let withoutElements = try ObsidianMarkdownParser.parse(fileName: "Rates", contents: page, fallbackTitle: "Rates")
        XCTAssertEqual(withElements.text, withoutElements.text, "Margin anchors index this text, so it must not move")
        XCTAssertEqual(withElements.headings, withoutElements.headings)
        XCTAssertTrue(withoutElements.elements.isEmpty)
        XCTAssertFalse(withElements.text.contains("substackcdn"), "no address is read aloud")
        XCTAssertFalse(withElements.text.contains("https://"))
    }

    func testAPageWithNoneOfThemHasNoElements() throws {
        let plain = try parse("# Notes\n\n\(prose("Only"))\n\n\(prose("Prose"))")
        XCTAssertEqual(plain.elements, [])
    }

    /// The owner asked for every web article, not only Substack (2026-11-14). A file from disk has no page address.
    func testEveryWebPageKeepsElementsAndAFileKeepsNone() throws {
        let markdown = "# Post\n\nSee [a link](https://example.com/a).\n\n![alt](https://cdn.example.com/p.jpg)\n\n\(prose("Body"))"
        let otherSite = try parse(markdown, sourceURL: "https://news.example.com/story")
        XCTAssertEqual(otherSite.elements.map(\.kind), [.link, .picture])
        XCTAssertEqual(try parse(markdown, sourceURL: "http://plain.example.com/x").elements.count, 2)
        XCTAssertEqual(try ObsidianMarkdownParser.parse(fileName: "Post", contents: markdown).elements, [])
        XCTAssertEqual(try parse(markdown, sourceURL: "file:///Users/x/Post.md").elements, [])
        XCTAssertEqual(try parse(markdown, sourceURL: "not a url").elements, [])
    }

    func testNeighbouringInputs() throws {
        func elements(_ body: String) throws -> [SourceElement] {
            try parse("# Post\n\n\(prose("Lead"))\n\n\(body)\n\n\(prose("Tail"))").elements
        }
        // Links that are not links a listener can follow, and the page's own buttons.
        XCTAssertEqual(try elements("[top](#top) [mail](mailto:a@b.co) [call](tel:123) [js](javascript:void(0)) [rel](/relative)"), [])
        XCTAssertEqual(try elements("[Subscribe now](https://example.substack.com/subscribe?utm=x) [Share](https://example.substack.com/p/x?action=share) [Comments](https://example.substack.com/p/x/comments)"), [])
        // A picture is not a link, and an inline picture in a sentence is not a row.
        XCTAssertEqual(try elements("Text with ![inline](https://substackcdn.com/i.jpg) picture in a sentence."), [])
        // Parentheses in the address, a title after it, mixed case host, empty alt.
        let wiki = try elements("Read [Margin](https://en.wikipedia.org/wiki/Margin_(typography) \"Margin\") now.")
        XCTAssertEqual(wiki.map(\.url), ["https://en.wikipedia.org/wiki/Margin_(typography)"])
        XCTAssertEqual(wiki.map(\.label), ["Margin"])
        XCTAssertEqual(try elements("![](https://VIMEO.com/12345)").map(\.label), ["Vimeo video"])
        XCTAssertEqual(try elements("![](https://open.spotify.com/episode/x)").map(\.kind), [.embed])
        XCTAssertEqual(try elements("![](https://notyoutube.com/watch?v=1)").map(\.kind), [.picture], "a lookalike host is not a video")
        // Alt text that is a file name says nothing; real alt text is kept when there is no caption.
        let named = try elements("![IMG_2041.jpeg](https://substackcdn.com/a.jpeg)\n\n# Next section")
        XCTAssertEqual(named.map(\.label), ["Picture"])
        XCTAssertNil(named.first?.altText)
        XCTAssertEqual(try elements("![Sunset over the bay](https://substackcdn.com/s.jpeg)\n\n# Next section").map(\.label), ["Sunset over the bay"])
        // A long paragraph after a picture is prose, not a caption.
        let long = Array(repeating: "This sentence is part of a long paragraph of prose.", count: 8).joined(separator: " ")
        XCTAssertEqual(try elements("![Alt words](https://substackcdn.com/l.jpeg)\n\n\(long)").map(\.label), ["Alt words"])
        // A heading after a picture is not its caption.
        XCTAssertEqual(try elements("![](https://substackcdn.com/h.jpeg)\n\n## A heading").map(\.label), ["Picture"])
        // Unicode link words and an emphasised caption.
        let unicode = try elements("Voir [l’étude — « Café »](https://example.fr/étude) ici.")
        XCTAssertEqual(unicode.count, 1)
        XCTAssertEqual(unicode.first?.kind, .link)
        XCTAssertEqual(try elements("![](https://substackcdn.com/e.jpeg)\n\n*Figure 2: the curve*").map(\.label), ["Figure 2: the curve"])
        // The same picture twice gives one row; two different pictures give two.
        XCTAssertEqual(try elements("![](https://substackcdn.com/d.jpeg)\n\n![](https://substackcdn.com/d.jpeg)").count, 1)
        XCTAssertEqual(try elements("![](https://substackcdn.com/d.jpeg)\n\n![](https://substackcdn.com/e.jpeg)").count, 2)
        // A picture at the very end of the page is anchored at the end of the text, never past it.
        let tail = try parse("# Post\n\n\(prose("Lead"))\n\n![](https://substackcdn.com/z.jpeg)")
        XCTAssertEqual(tail.elements.first?.start, tail.text.count)
        // A very long caption is shortened.
        let label = SourceElementCapture.shortened(String(repeating: "word ", count: 80))
        XCTAssertLessThanOrEqual(label.count, SourceElementCapture.maximumLabelLength)
    }

    // MARK: Storing and loading

    func testRecordIsOnlyAppliedToTheTextItWasMadeFor() throws {
        let parsed = try parse(page)
        let record = SourceElementsRecord(text: parsed.text, elements: parsed.elements)
        XCTAssertEqual(record.elements(for: parsed.text), parsed.elements)
        XCTAssertEqual(record.elements(for: parsed.text + " edited"), [], "elements never move onto changed text")
    }

    func testStoreRoundTripsAndDeletesWithTheItem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("elements-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appendingPathComponent("test.sqlite").path)
        let parsed = try parse(page)
        let item = Item(id: "item-a", title: "Rates", mediaType: "text", text: parsed.text, externalReference: sourceURL,
                        status: "ready", externalReferenceType: "url", createdAt: Date())
        try store.saveItem(item)
        try store.saveSourceElements(SourceElementsRecord(text: parsed.text, elements: parsed.elements), itemId: "item-a")
        let loaded = try XCTUnwrap(try store.loadSourceElements(itemId: "item-a"))
        XCTAssertEqual(loaded.elements(for: parsed.text), parsed.elements)
        XCTAssertNil(try store.loadSourceElements(itemId: "item-b"))

        let reopened = try SQLiteSessionStore(path: directory.appendingPathComponent("test.sqlite").path)
        XCTAssertEqual(try reopened.loadSourceElements(itemId: "item-a")?.elements.count, parsed.elements.count)

        try store.deleteItem(id: "item-a")
        XCTAssertNil(try store.loadSourceElements(itemId: "item-a"))
    }

    func testImportKeepsElementsAndTimelineSourceCarriesThem() throws {
        let repository = InMemorySessionRepository()
        let handoff = BrowserTextHandoff(
            captureMode: .readablePage, source: BrowserTextSource(url: sourceURL, title: "Rates"), text: page,
            contentFormat: .markdown)
        let importer = BrowserTextImporter(repository: repository, openItemIds: [], isPlaybackActive: false, publisherPlayback: [:])
        let outcome = try importer.outcomeAndPersist(handoff, structuredDocument: nil, upgrade: .skip)
        guard case .records(let item, _, _, _) = outcome else { return XCTFail("expected records") }

        let stored = try XCTUnwrap(try repository.loadSourceElements(itemId: item.id))
        let text = try XCTUnwrap(item.text)
        let elements = stored.elements(for: text)
        XCTAssertEqual(elements.count, 5, "two pictures, one video, two links; the repeated address is dropped")

        let detail = ItemDetailState(id: item.id, title: item.title, text: text).includingTimelineSource(nil, elements: stored)
        XCTAssertEqual(detail.timelineSource.elements, elements)
        XCTAssertEqual(detail.timelineSource.entries.map(\.text).joined(separator: "\n\n").isEmpty, false)

        let withoutRecord = ItemDetailState(id: item.id, title: item.title, text: text).includingTimelineSource(nil)
        XCTAssertEqual(withoutRecord.timelineSource.elements, [], "an item imported before this keeps its Timeline as it was")
    }

    func testAnotherSitesPageKeepsItsElements() throws {
        let repository = InMemorySessionRepository()
        let importer = BrowserTextImporter(repository: repository, openItemIds: [], isPlaybackActive: false, publisherPlayback: [:])
        let other = BrowserTextHandoff(
            captureMode: .readablePage, source: BrowserTextSource(url: "https://news.example.com/story", title: "Story"),
            text: "# Story\n\n\(prose("Lead"))\n\nSee [a link](https://example.com/a).\n\n\(prose("Tail"))",
            contentFormat: .markdown)
        _ = try importer.outcomeAndPersist(other, structuredDocument: nil, upgrade: .skip)
        XCTAssertEqual(repository.sourceElements.values.first?.elements.map(\.url), ["https://example.com/a"])
    }

    func testLinksWhosePathOnlyStartsLikePageChromeAreKept() throws {
        let urls = ["https://example.com/accountability-report", "https://example.com/shareholder-letter",
                    "https://example.com/subscribers-guide", "https://example.com/comments-policy"]
        let body = urls.enumerated().map { "[link \($0.offset)](\($0.element))" }.joined(separator: " ")
        let parsed = try parse("# Post\n\n\(prose("Lead"))\n\n\(body)\n\n\(prose("Tail"))")
        XCTAssertEqual(parsed.elements.map(\.url), urls)
        XCTAssertEqual(SourceElementCapture.inlineLinks(in: "[x](https://a.substack.com/subscribe/)").count, 0)
        XCTAssertEqual(SourceElementCapture.inlineLinks(in: "[x](https://a.substack.com/account)").count, 0)
    }

    func testLabelsAreCleanedTheWayTheTextIs() throws {
        func labels(_ body: String) throws -> [String] {
            try parse("# Post\n\n\(prose("Lead"))\n\n\(body)\n\n\(prose("Tail"))").elements.map(\.label)
        }
        XCTAssertEqual(try labels("![](https://substackcdn.com/a.jpg)\n\n**Source:** the Fed"), ["Source: the Fed"])
        XCTAssertEqual(try labels("![](https://substackcdn.com/b.jpg)\n\nA *very* **bold** `code` caption"), ["A very bold code caption"])
        XCTAssertEqual(try labels("![](https://substackcdn.com/c.jpg)\n\nSee [the report](https://example.com/r) for more"), ["See the report for more", "the report"], "the caption's link is a link row too")
        XCTAssertEqual(try labels("Read [snake\\_case name](https://example.com/s) now."), ["snake_case name"])
        XCTAssertEqual(try labels("Read [this **bold** link](https://example.com/b) now."), ["this bold link"])
    }

    func testALinkAnchorsOnItsOwnWordsNotAnEarlierMatch() throws {
        let parsed = try parse("# Post\n\n\(prose("Lead"))\n\nI wrote a post about this post, see [post](https://example.com/p) now.\n\n\(prose("Tail"))")
        let link = try XCTUnwrap(parsed.elements.first)
        XCTAssertEqual(link.start, try start(of: "see post now", in: parsed.text) + 4)
    }

    func testPicturesAndLinksAtTheSameStartKeepTextOrder() throws {
        let pictures = (0..<12).map { "![](https://substackcdn.com/p\($0).jpg)" }.joined(separator: "\n\n")
        let parsed = try parse("# Post\n\n\(pictures)\n\n\(prose("Tail"))")
        XCTAssertEqual(parsed.elements.count, 12)
        XCTAssertEqual(parsed.elements.map(\.url), (0..<12).map { "https://substackcdn.com/p\($0).jpg" })
        XCTAssertEqual(parsed.elements.map(\.id).sorted(), parsed.elements.map(\.id), "ids sort the way the elements read")
    }

    func testAPictureUnderAParagraphWithNoBlankLineAnchorsOnTheNextPassage() throws {
        let parsed = try parse("# Post\n\nLead para.\n![](https://substackcdn.com/q.jpg)\n\nNext para.\n\n\(prose("Tail"))")
        XCTAssertEqual(parsed.elements.first?.start, try start(of: "Next para.", in: parsed.text))
    }

    func testAPictureWrappedInALinkIsAPictureAndItsTextIsUnchanged() throws {
        let wrapped = "# Post\n\n\(prose("Lead"))\n\n[![A map](https://substackcdn.com/m.jpg)](https://substackcdn.com/full/m.jpg)\n\nThe map caption.\n\n\(prose("Tail"))"
        let parsed = try parse(wrapped)
        XCTAssertEqual(parsed.elements.map(\.kind), [.picture])
        XCTAssertEqual(parsed.elements.first?.url, "https://substackcdn.com/m.jpg")
        XCTAssertEqual(parsed.elements.first?.label, "The map caption.")
        let plain = try ObsidianMarkdownParser.parse(fileName: "Rates", contents: wrapped, fallbackTitle: "Rates")
        XCTAssertEqual(parsed.text, plain.text)
    }

    func testTheTextIsExactlyWhatTheParserGaveBeforeThisChange() throws {
        let markdown = "# Rates\n\nOne.\n\n![A chart](https://substackcdn.com/image/a.jpg)\n\nCaption here.\n\nSee [the study](https://example.com/study) and [**bold** link](https://other.org/x).\n\n![](https://www.youtube.com/watch?v=abc)\n\nTwo."
        // Written out by hand from the parser as it was before #2032: picture lines dropped, links keep their words.
        XCTAssertEqual(try parse(markdown).text, "Rates\n\nOne.\n\nCaption here.\n\nSee the study and bold link.\n\nTwo.")
    }

    func testARecordWithAnElementThisBuildCannotReadStillLoads() throws {
        let json = """
        {"schemaVersion":"source-elements.v1","textSHA256":"abc","elements":[
        {"id":"e00000","kind":"picture","start":0,"label":"A","url":"https://x.example/a.jpg"},
        {"id":"e00001","kind":"hologram","start":5,"label":"B","url":"https://x.example/b"}]}
        """
        let record = try JSONDecoder().decode(SourceElementsRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.elements.map(\.id), ["e00000"])
    }

    func testCapturingElementsLeavesTheTextAsItWas() throws {
        let markdown = "# Notes\n\n[a link](https://example.com/a)\n\n![pic](https://cdn.example.com/p.jpg)\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n\(prose("Body"))"
        let withSource = try parse(markdown, sourceURL: "https://news.example.com/x")
        let without = try ObsidianMarkdownParser.parse(fileName: "Rates", contents: markdown, fallbackTitle: "Rates")
        XCTAssertEqual(withSource.elements.count, 3)
        XCTAssertEqual(withSource.text, without.text)
        XCTAssertEqual(withSource.headings, without.headings)
    }

    func testALinkOnlyOrLinkedPictureLineAfterAPictureIsNotItsCaption() throws {
        func label(_ next: String) throws -> String? {
            try parse("# Post\n\n\(prose("Lead"))\n\n![](https://substackcdn.com/c.jpg)\n\n\(next)\n\n\(prose("Tail"))").elements.first?.label
        }
        XCTAssertEqual(try label("[Read more](https://example.com/more)"), "Picture")
        XCTAssertEqual(try label("[![A](https://substackcdn.com/d.jpg)](https://example.com/v)"), "Picture")
    }

    func testALinkInAListOrHeadingAnchorsOnItsOwnWords() throws {
        let parsed = try parse("# Post\n\n\(prose("Lead"))\n\n- the post about this post [post](https://example.com/p)\n\n\(prose("Tail"))")
        let link = try XCTUnwrap(parsed.elements.first)
        XCTAssertEqual(link.start, try start(of: "this post post", in: parsed.text) + "this post ".count)
    }

    func testReimportWithNoElementsReplacesTheOldRecord() throws {
        let repository = InMemorySessionRepository()
        let importer = BrowserTextImporter(repository: repository, openItemIds: [], isPlaybackActive: false, publisherPlayback: [:])
        func handoff(_ body: String) -> BrowserTextHandoff {
            BrowserTextHandoff(captureMode: .readablePage, source: BrowserTextSource(url: sourceURL, title: "Rates"),
                               text: "# Rates\n\n\(prose("Lead"))\n\n\(body)\n\n\(prose("Tail"))", contentFormat: .markdown)
        }
        // A picture line never reaches the text, so removing it leaves the text as it was.
        _ = try importer.outcomeAndPersist(handoff("![](https://substackcdn.com/x.jpg)"), structuredDocument: nil, upgrade: .skip)
        XCTAssertEqual(repository.sourceElements.values.first?.elements.count, 1)
        _ = try importer.outcomeAndPersist(handoff(""), structuredDocument: nil, upgrade: .skip)
        XCTAssertEqual(repository.sourceElements.values.first?.elements, [], "the removed picture's row is gone")
    }

    func testReimportOfACustomDomainPageThatLostItsLastSubstackPictureReplacesTheRecord() throws {
        let repository = InMemorySessionRepository()
        let importer = BrowserTextImporter(repository: repository, openItemIds: [], isPlaybackActive: false, publisherPlayback: [:])
        func handoff(_ body: String) -> BrowserTextHandoff {
            BrowserTextHandoff(captureMode: .readablePage, source: BrowserTextSource(url: "https://www.example.org/p/rates", title: "Rates"),
                               text: "# Rates\n\n\(prose("Lead"))\n\n\(body)\n\n\(prose("Tail"))", contentFormat: .markdown)
        }
        _ = try importer.outcomeAndPersist(handoff("![](https://substackcdn.com/x.jpg)"), structuredDocument: nil, upgrade: .skip)
        XCTAssertEqual(repository.sourceElements.values.first?.elements.count, 1)
        // Nothing on the page says Substack any more.
        _ = try importer.outcomeAndPersist(handoff(""), structuredDocument: nil, upgrade: .skip)
        XCTAssertEqual(repository.sourceElements.values.first?.elements, [])
    }

    func testANumberedListLinkAnchorsOnItsOwnWords() throws {
        let parsed = try parse("# Post\n\n\(prose("Lead"))\n\n1. the post about this post [post](https://example.com/p)\n\n\(prose("Tail"))")
        let link = try XCTUnwrap(parsed.elements.first)
        XCTAssertEqual(link.start, try start(of: "this post post", in: parsed.text) + "this post ".count)
    }

    // MARK: Tables (2026-11-14)

    private func tables(_ markdown: String) throws -> [SourceElement] {
        try parse("# Post\n\n\(prose("Lead"))\n\n\(markdown)\n\n\(prose("Tail"))").elements.filter { $0.kind == .table }
    }

    func testATableIsKeptWithItsCellsAndAnchorsOnItsFirstLine() throws {
        let parsed = try parse("# Post\n\n\(prose("Lead"))\n\n| Model | **Cost** | Speed |\n| :--- | :---: | ---: |\n| Small | $1 | fast |\n| Large | $9 | [slow](https://example.com/s) |\n\n\(prose("Tail"))")
        let table = try XCTUnwrap(parsed.elements.first { $0.kind == .table })
        XCTAssertEqual(table.label, "Model · Cost · Speed")
        XCTAssertEqual(table.rows, [["Model", "Cost", "Speed"], ["Small", "$1", "fast"], ["Large", "$9", "slow"]])
        XCTAssertEqual(table.url, "")
        XCTAssertEqual(table.start, try start(of: "| Model", in: parsed.text))
        XCTAssertTrue(parsed.elements.contains { $0.kind == .link && $0.url == "https://example.com/s" }, "a link in a cell is still a link")
    }

    /// Neighbouring inputs: escaped pipes, short rows, no closing pipe, an empty header, a pipe line with no divider,
    /// two tables in a row, a table that ends the text, and a table straight after a paragraph.
    func testTableNeighbouringInputs() throws {
        XCTAssertEqual(try tables("| A \\| B | C |\n| --- | --- |\n| 1 | 2 |").first?.rows, [["A | B", "C"], ["1", "2"]])
        XCTAssertEqual(try tables("| A | B | C |\n| --- | --- | --- |\n| 1 |").first?.rows, [["A", "B", "C"], ["1", "", ""]])
        XCTAssertEqual(try tables("| A | B\n| --- | ---\n| 1 | 2").first?.rows, [["A", "B"], ["1", "2"]])
        XCTAssertEqual(try tables("|  |  |\n| --- | --- |\n| 1 | 2 |"), [], "a header with no words")
        XCTAssertEqual(try tables("| not | a table |\n| just pipes |"), [])
        XCTAssertEqual(try tables("| A |\n| --- |\n| 1 |\n\n| B |\n| --- |\n| 2 |").map(\.label), ["A", "B"])
        XCTAssertEqual(try tables("Intro line.\n| A |\n| --- |\n| 1 |").map(\.rows), [[["A"], ["1"]]])
        let atEnd = try parse("# Post\n\n\(prose("Lead"))\n\n| A | B |\n| --- | --- |\n| 1 | 2 |").elements
        XCTAssertEqual(atEnd.filter { $0.kind == .table }.count, 1)
        XCTAssertEqual(try tables("| Café | naïve |\n| --- | --- |\n| 1 | 2 |").first?.label, "Café · naïve")
    }

    /// GFM tables the first parser missed or misread (audit on a9dc647): no outer pipes, dividers of one or two dashes,
    /// a pipe line straight above the header, a lone pipe line over a thematic break, and a body row without a
    /// leading pipe. A `|` inside inline code still splits its cell, as GFM says; only `\|` keeps it.
    func testGFMTableShapesTheFirstParserMissed() throws {
        XCTAssertEqual(try tables("A | B\n--- | ---\n1 | 2").first?.rows, [["A", "B"], ["1", "2"]], "no outer pipes")
        XCTAssertEqual(try tables("| A | B |\n|-|-|\n| 1 | 2 |").first?.rows, [["A", "B"], ["1", "2"]], "one-dash divider")
        XCTAssertEqual(try tables("| A |\n| :-: |\n| 1 |").first?.rows, [["A"], ["1"]], "centred one-dash divider")
        XCTAssertEqual(try tables("| A | B |\n| -- | :- |\n| 1 | 2 |").first?.rows, [["A", "B"], ["1", "2"]], "two-dash divider")
        XCTAssertEqual(try tables("| just a line\n\n---\n\n\(prose("More"))"), [], "a pipe line over a break is not a table")
        XCTAssertEqual(try tables("| just a line\n---"), [], "a pipe line over a Setext underline is not a table")
        XCTAssertEqual(try tables("| note |\n| A | B |\n| --- | --- |\n| 1 | 2 |").map(\.rows), [[["A", "B"], ["1", "2"]]],
                       "a pipe line above the header does not hide the table")
        XCTAssertEqual(try tables("| A | B |\n| --- | --- |\n1 | 2\n| 3 | 4 |").first?.rows, [["A", "B"], ["1", "2"], ["3", "4"]],
                       "a body row without a leading pipe stays in the table")
        XCTAssertEqual(try tables("| A | B |\n| --- |\n| 1 | 2 |"), [], "a divider narrower than its header is not a table")
        XCTAssertEqual(try tables("| A | B |\n| --- | --- |\n| 1 | 2 |\n| --- | --- |").first?.rows,
                       [["A", "B"], ["1", "2"], ["---", "---"]], "only the second line is the divider")
        XCTAssertEqual(try tables("Price -- not a | table\n\n\(prose("More"))"), [])
    }

    private let tableBlock = "| A | B |\n| --- | --- |\n| 1 | 2 |"

    /// #4451: the page shows code in a fence as code, so table-like text in one is no Table row. A fence is three or
    /// more backticks or tildes, indented up to three spaces, closed by the same mark at least as long; an unclosed
    /// fence runs to the end. A line like "```code```" is inline code and opens nothing.
    func testTableLikeTextInACodeFenceIsNotATable() throws {
        XCTAssertEqual(try tables("```\n\(tableBlock)\n```"), [], "backtick fence")
        XCTAssertEqual(try tables("~~~\n\(tableBlock)\n~~~"), [], "tilde fence")
        XCTAssertEqual(try tables("```markdown\n\(tableBlock)\n```"), [], "a fence with an info string")
        XCTAssertEqual(try tables("   ```\n\(tableBlock)\n   ```"), [], "a fence indented three spaces")
        XCTAssertEqual(try tables("````\n```\n\(tableBlock)\n```\n````"), [], "a shorter fence does not close a longer one")
        XCTAssertEqual(try tables("~~~\n```\n\(tableBlock)\n```\n~~~"), [], "another mark does not close a fence")
        XCTAssertEqual(try tables("```\n\(tableBlock)"), [], "an unclosed fence runs to the end")
        XCTAssertEqual(try tables("```\ncode\n```\n\n\(tableBlock)").map(\.label), ["A · B"], "a table after a closed fence")
        XCTAssertEqual(try tables("\(tableBlock)\n\n```\n\(tableBlock)\n```").map(\.label), ["A · B"], "only the one outside the fence")
        XCTAssertEqual(try tables("```not a fence```\n\n\(tableBlock)").map(\.label), ["A · B"], "inline code opens no fence")
        XCTAssertEqual(try tables("```\ncode\n``` trailing\n\(tableBlock)\n```").map(\.label), [],
                       "a closing mark with words after it does not close")
        XCTAssertEqual(try tables("| A | B |\n| --- | --- |\n| 1 | 2 |\n```\n| 3 | 4 |\n```").first?.rows, [["A", "B"], ["1", "2"]],
                       "a fence ends the table above it and its lines are not rows")
    }

    /// The same class: a picture or a link written inside a fence is code too. The text is exactly what it was.
    func testPicturesAndLinksInACodeFenceAreNotElements() throws {
        let fenced = "```\nsee [a](https://a.example/x)\n\n![](https://substackcdn.com/image/c.jpg)\n[![p](https://substackcdn.com/image/d.jpg)](https://a.example/y)\n```"
        let markdown = "# Post\n\n\(prose("Lead"))\n\n\(fenced)\n\n[outside](https://b.example/z)\n\n\(prose("Tail"))"
        let parsed = try parse(markdown)
        XCTAssertEqual(parsed.elements.map(\.kind), [.link])
        XCTAssertEqual(parsed.elements.first?.url, "https://b.example/z")
        let without = try ObsidianMarkdownParser.parse(fileName: "Rates", contents: markdown, fallbackTitle: "Rates")
        XCTAssertEqual(parsed.text, without.text)
    }

    /// #4451, GFM: a table is broken at the first blank line or the start of another block; every other line below the
    /// divider is a body row, with or without a pipe, padded to the header's width.
    func testRowsWithoutAPipeAfterATableAreDecidedByGFM() throws {
        XCTAssertEqual(try tables("\(tableBlock)\nplain row").first?.rows, [["A", "B"], ["1", "2"], ["plain row", ""]],
                       "a line with no pipe is a body row")
        XCTAssertEqual(try tables("\(tableBlock)\nplain row\n| 3 | 4 |").first?.rows,
                       [["A", "B"], ["1", "2"], ["plain row", ""], ["3", "4"]], "and the table goes on after it")
        XCTAssertEqual(try tables("\(tableBlock)\nsee this | that").first?.rows, [["A", "B"], ["1", "2"], ["see this", "that"]],
                       "a paragraph line with a pipe is a body row too (GFM)")
        XCTAssertEqual(try tables("\(tableBlock)\n\nplain line").first?.rows, [["A", "B"], ["1", "2"]], "a blank line ends it")
        XCTAssertEqual(try tables("\(tableBlock)\n   \nplain line").first?.rows, [["A", "B"], ["1", "2"]], "so does a line of spaces")
        for block in ["> quote", "# Heading", "## Heading ##", "- item", "* item", "+ item", "1. item", "2) item", "---", "* * *",
                      "___", "<div>", "<!-- note -->", "```", "~~~"] {
            XCTAssertEqual(try tables("\(tableBlock)\n\(block)").first?.rows, [["A", "B"], ["1", "2"]], "\(block) starts another block")
        }
        for notABlock in ["#hashtag", "-5 degrees", "*emphasis* here", "1.5 million", "2024 was a year", "<3 love", "--", "~~strike~~"] {
            XCTAssertEqual(try tables("\(tableBlock)\n\(notABlock)").first?.rows?.count, 3, "\(notABlock) is a body row")
        }
        for inline in ["<a href=\"x\">link</a> | y", "<em>x</em> | y", "<https://a.example> | y", "<span>a</span>", "    - item", "    # code"] {
            XCTAssertEqual(try tables("\(tableBlock)\n\(inline)").first?.rows?.count, 3, "\(inline) is a body row")
        }
        for html in ["<div>", "<p>text", "</div>", "<table>", "<br/>", "<custom-tag>", "<?php", "<!DOCTYPE html>", "  <hr>"] {
            XCTAssertEqual(try tables("\(tableBlock)\n\(html)").first?.rows?.count, 2, "\(html) starts an HTML block")
        }
        // A picture on a line of its own under a table is a picture, not a row of cells.
        let withPicture = try parse("# Post\n\n\(prose("Lead"))\n\n\(tableBlock)\n![](https://substackcdn.com/image/c.jpg)\nCaption words.\n\n\(prose("Tail"))")
        XCTAssertEqual(withPicture.elements.map(\.kind), [.table, .picture])
        XCTAssertEqual(withPicture.elements.first?.rows, [["A", "B"], ["1", "2"]])
        XCTAssertEqual(try tables("\(tableBlock)\n\\|").first?.rows?.last, ["|", ""], "a lone escaped pipe is a one-cell row")
        // The page text never changes, only the preview grid.
        let markdown = "# Post\n\n\(prose("Lead"))\n\n\(tableBlock)\nplain row\n\n\(prose("Tail"))"
        let without = try ObsidianMarkdownParser.parse(fileName: "Rates", contents: markdown, fallbackTitle: "Rates")
        XCTAssertEqual(try parse(markdown).text, without.text)
    }

    func testARecordWithATableRoundTripsAndAnOlderReaderSkipsIt() throws {
        let table = SourceElement(id: "e00000", kind: .table, start: 3, label: "A · B", url: "", rows: [["A", "B"], ["1", "2"]])
        let picture = SourceElement(id: "e00001", kind: .picture, start: 9, label: "P", url: "https://x.example/p.jpg")
        let record = SourceElementsRecord(text: "some text here", elements: [table, picture])
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(SourceElementsRecord.self, from: data), record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"rows\":null"), "a picture writes no rows key, as before tables")
    }
}
