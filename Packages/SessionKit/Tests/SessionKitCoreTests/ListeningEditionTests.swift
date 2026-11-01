import XCTest
@testable import SessionKit
import SessionKitTestInputs
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ListeningEditionTests: XCTestCase {
    func testShortcutImportAcceptsAFileOrJSONTextThroughOneDecodePath() throws {
        // #574: Import Listening Edition stopped at a file picker on every run. A file (Assemble's output
        // or a saved one) and the JSON as text must reach the same decoder.
        let data = try TestInputs.data(.contracts, "fixtures/listening-editions/article.json")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let expected = try ListeningEdition.decode(data)
        for (name, file, json) in [("file", data as Data?, nil as String?), ("text", nil, text),
                                   ("text with surrounding whitespace", nil, "\n  " + text + "\n"),
                                   ("an empty file and text", Data(), text), ("both: the file wins", data, "not json")] {
            XCTAssertEqual(try ListeningEdition.decode(ListeningEdition.shortcutInput(file: file, text: json)), expected, name)
        }
    }

    func testShortcutImportWithNothingOrABadEditionSaysWhatToDo() throws {
        for (name, file, json) in [("nothing", nil as Data?, nil as String?), ("empty file and empty text", Data(), ""),
                                   ("whitespace text", nil, " \n\t ")] {
            XCTAssertThrowsError(try ListeningEdition.shortcutInput(file: file, text: json), name) {
                XCTAssertTrue(($0 as? EditionError)?.errorDescription?.contains("Assemble Listening Edition") == true, name)
            }
        }
        // The existing readable errors still come from decode, for text and for files alike.
        let notJSON = try ListeningEdition.shortcutInput(file: nil, text: "not json at all")
        XCTAssertThrowsError(try ListeningEdition.decode(notJSON))
        let mapOnly = try ListeningEdition.shortcutInput(file: nil, text: #"{"overview":"o","scenes":[]}"#)
        XCTAssertThrowsError(try ListeningEdition.decode(mapOnly)) {
            XCTAssertTrue(($0 as? EditionError)?.errorDescription?.contains("Listening Map response") == true)
        }
    }

    func testPublishedFixtureDecodesThroughRuntimeContract() throws {
        let data = try TestInputs.data(.contracts, "fixtures/listening-editions/article.json")
        let edition = try ListeningEdition.decode(data)
        XCTAssertEqual(edition.scenes.count, 2)
        XCTAssertEqual(edition.listeningMap().chapters.count, 2)
    }

    func testShortcutJSONAcceptsFencesAndExplainsMapOnlyOutput() throws {
        let map = #"{"overview":"Brief","scenes":[{"title":"One","description":"Orientation","summary":"Summary","startBlock":1,"endBlock":1}]}"#
        let edition = try ListeningEdition.assemble(title: "Article", sourceURL: "https://example.com/a", text: "Source.", generator: "Ask ChatGPT", mapJSON: "```json\n\(map)\n```")
        let fencedEdition = "```json\n\(String(decoding: try edition.encoded(), as: UTF8.self))\n```"
        XCTAssertEqual(try ListeningEdition.decode(Data(fencedEdition.utf8)), edition)
        XCTAssertThrowsError(try ListeningEdition.decode(Data(map.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Assemble Listening Edition"))
        }
        XCTAssertThrowsError(try ListeningEdition.assemble(title: "Article", sourceURL: nil, text: "Source.", generator: "Ask ChatGPT", mapJSON: "Here is the JSON: \(map)")) { error in
            XCTAssertTrue(error.localizedDescription.contains("one JSON object"))
        }
    }

    func testAssemblyPreservesOriginalUnicodeAndRejectsInvalidCoverage() throws {
        let original = "  First 👩🏽‍💻 passage.\n\nSecond e\u{301} passage.  "
        let json = #"{"overview":"A map","scenes":[{"title":"One","description":"Orientation","summary":"A summary","startBlock":1,"endBlock":1},{"title":"Two","description":"More","summary":"Another summary","startBlock":2,"endBlock":2}]}"#
        let edition = try ListeningEdition.assemble(title: "Example", sourceURL: "https://example.com/article", text: original, generator: "My model", mapJSON: json)
        XCTAssertEqual(edition.text, original)
        XCTAssertEqual(edition.listeningMap().chapters[1].startChar, 20)
        XCTAssertEqual(try ListeningEdition.decode(edition.encoded()), edition)
        var broken = edition
        broken.scenes[1].startBlock = 1
        XCTAssertThrowsError(try broken.validated())
        broken = edition; broken.scenes.removeLast()
        XCTAssertThrowsError(try broken.validated())
        broken = edition; broken.scenes[1].endBlock = 100
        XCTAssertThrowsError(try broken.validated())
        broken = edition; broken.sourceURL = "file:///private/source"
        XCTAssertThrowsError(try broken.validated())
    }
    func testSourceIdentitySurvivesMapRevisionButNotChangedText() throws {
        let a = ListeningEdition(title: "T", text: "Source", generator: "External model", overview: "O", scenes: [.init(title: "A", description: "D", summary: "S", startBlock: 1, endBlock: 1)])
        var b = a; b.scenes[0].summary = "Revised summary"
        XCTAssertEqual(a.itemID, b.itemID)
        XCTAssertNotEqual(a.revision, b.revision)
        b.text = "Different source"
        XCTAssertNotEqual(a.itemID, b.itemID)
    }
    func testAudioMapRequiresCompleteRealSegmentsAndKeepsSummarySeparate() throws {
        let a = ListeningEdition(title: "T", text: "First.\n\nSecond.", generator: "User", overview: "O", scenes: [
            .init(title: "One", description: "Description one", summary: "Summary one", startBlock: 1, endBlock: 1),
            .init(title: "Two", description: "Description two", summary: "Summary two", startBlock: 2, endBlock: 2)])
        let timeline = TranscriptTimeline(segments: [
            .init(id: "1", startMs: 0, endMs: 1200, startChar: 0, endChar: 8, text: "First."),
            .init(id: "2", startMs: 1200, endMs: 3700, startChar: 8, endChar: 15, text: "Second.")
        ], chapters: [], durationMs: 3700)
        let (proposal, projection) = try a.audioMap(timeline: timeline)
        XCTAssertEqual(proposal.scenes[1].startAnchor.mediaTimeMs, 1200)
        XCTAssertEqual(proposal.scenes[0].summaryText, "Summary one")
        XCTAssertEqual(projection.projectedRecipientTime(for: 3700), 3700)
        var partial = timeline; partial.segments.removeLast()
        XCTAssertThrowsError(try a.audioMap(timeline: partial))
    }
}

final class ReadLaterClientTests: XCTestCase {
    func testReaderFiltersChildRecordsAndSuppliesAuthAndPagination() async throws {
        let client = ReadLaterClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token private-token")
            XCTAssertTrue(request.url!.absoluteString.contains("pageCursor=next-page"))
            XCTAssertTrue(request.url!.absoluteString.contains("withHtmlContent=true"))
            let json = #"{"results":[{"id":"a","title":"Article","source_url":"https://example.com/a","category":"article","html_content":"<p>Full source</p>"},{"id":"h","title":"Private highlight","url":"https://example.com/h","category":"highlight","parent_id":"a"},{"id":"p","url":"https://example.com/p","category":"pdf"}],"nextPageCursor":"last"}"#
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let page = try await client.page(service: .reader, token: "private-token", cursor: "next-page")
        XCTAssertEqual(page.documents.map(\.id), ["reader:a"])
        XCTAssertEqual(page.documents[0].html, "<p>Full source</p>")
        XCTAssertEqual(page.nextCursor, "last")
    }
    func testRateLimitDoesNotReturnPartialSuccess() async {
        let client = ReadLaterClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.page(service: .reader, token: "x"); XCTFail("Must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rate limit")) }
    }
    func testReaderNotFoundSaysTheAccountHasNoReader() async {
        // #621: a working token on a Readwise account without Reader gets 404 from /api/v3/list/.
        let client = ReadLaterClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.page(service: .reader, token: "x"); XCTFail("Must fail") }
        catch {
            XCTAssertEqual(error.localizedDescription, ReadLaterClient.readerUnavailableMessage)
            XCTAssertTrue(error.localizedDescription.contains("Reader isn’t available on this Readwise account"))
            XCTAssertTrue(error.localizedDescription.contains("highlights can still work"))
            XCTAssertFalse(error.localizedDescription.contains("Try again later"))
        }
    }
    func testOtherStatusCodesKeepTheirMessages() async {
        for (service, code, expected) in [(ReadLaterService.reader, 401, "Access was rejected"), (.reader, 500, "HTTP 500. Try again later"), (.raindrop, 404, "HTTP 404. Try again later")] {
            let client = ReadLaterClient { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await client.page(service: service, token: "x"); XCTFail("Must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected), "\(service) \(code): \(error.localizedDescription)") }
        }
        let laterPage = ReadLaterClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await laterPage.page(service: .reader, token: "x", cursor: "next"); XCTFail("Must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 404. Try again later"), error.localizedDescription) }
    }
    func testEmptyArticleListAlwaysSaysWhy() {
        func line(_ service: ReadLaterService = .reader, connected: Bool = true, isLoading: Bool = false, loaded: Bool = false, failure: String? = nil, count: Int = 0) -> String? {
            ReadLaterClient.emptyArticlesLine(service: service, connected: connected, isLoading: isLoading, loaded: loaded, failure: failure, documentCount: count)
        }
        XCTAssertNil(line(loaded: true, count: 2))
        XCTAssertEqual(line(isLoading: true), "Fetching articles…")
        XCTAssertEqual(line(connected: false), "Connect Readwise Reader above to list its articles here.")
        XCTAssertEqual(line(failure: ReadLaterClient.readerUnavailableMessage), "No articles loaded. " + ReadLaterClient.readerUnavailableMessage)
        XCTAssertEqual(line(), "Tap Refresh to list your articles.")
        XCTAssertEqual(line(loaded: true), "No articles to show. Your Reader Later list has no articles with text.")
        XCTAssertEqual(line(.raindrop, loaded: true), "No articles to show. Your Raindrop bookmarks list is empty.")
    }
    func testRaindropUsesBookmarksNotPaidCachedCopies() async throws {
        let client = ReadLaterClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-token")
            XCTAssertEqual(request.url?.path, "/rest/v1/raindrops/0")
            return (Data(#"{"result":true,"items":[{"_id":42,"title":"Read me","link":"https://example.com/read"},{"_id":43,"title":"Invalid","link":"javascript:alert(1)"}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let page = try await client.page(service: .raindrop, token: "local-token")
        XCTAssertEqual(page.documents.map(\.id), ["raindrop:42"])
        XCTAssertNil(page.documents.first?.html)
        XCTAssertNil(page.nextCursor)
    }
    func testTextMapProposalPlacesEachSceneByCharacterWithTheEditionsOwnSummaries() throws {
        let edition = try ListeningEdition.decode(TestInputs.data(.contracts, "fixtures/listening-editions/article.json"))
        let proposal = try edition.textMapProposal()
        let chapters = edition.listeningMap().chapters
        XCTAssertEqual(proposal.scenes.map(\.id), chapters.map(\.id), "a Skim destination is also a chapter")
        XCTAssertEqual(proposal.scenes.map { $0.startAnchor.startChar }, chapters.map { Optional($0.startChar) })
        XCTAssertEqual(proposal.scenes.map { $0.endAnchor.endChar }, chapters.map { Optional($0.endChar) })
        XCTAssertEqual(proposal.scenes.map(\.summaryText), edition.scenes.map { Optional($0.summary) })
        XCTAssertTrue(proposal.scenes.allSatisfy { $0.startAnchor.mediaTimeMs == nil && $0.eligibility == .eligible })
        XCTAssertTrue(proposal.id.hasPrefix(ListeningEditionMap.proposalIDPrefix))
        XCTAssertNotNil(SceneStarts.textProposal(in: [proposal]))
        let starts = SceneStarts(textScenes: proposal.scenes)
        XCTAssertEqual(starts.sceneStarts, chapters.map { Optional($0.startChar) })
        XCTAssertNotNil(starts.textSkimPlan(direction: .forward, at: chapters[0].startChar))
    }
}
