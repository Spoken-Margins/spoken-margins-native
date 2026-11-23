import UIKit
import XCTest
@testable import SessionKit
import SessionKitFeeds
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #4341, app-hosted: follow a Zotero list, see its row on Following, add one PDF paper and one abstract paper, and see
/// both In Library, through `PaperSourcesState` with a transport the test controls. The Zotero JSON here is a cut-down
/// copy of the real replies the host tests read (Contracts/fixtures/feeds/zotero-*.json): same fields, fewer rows.
@MainActor
final class PaperSourcesAppTests: XCTestCase {
    private final class Credentials: @unchecked Sendable {
        var values: [String: String] = [:]
        var store: ZoteroCredentialStore {
            ZoteroCredentialStore(load: { [self] in values[$0] }, save: { [self] value, account in values[account] = value.isEmpty ? nil : value })
        }
    }

    private final class Replies: @unchecked Sendable {
        var byPath: [String: PaperFetchReply] = [:]
        var requests: [URLRequest] = []
        var offline = false
        var transport: PaperTransport {
            { [self] request in
                requests.append(request)
                if offline { throw URLError(.notConnectedToInternet) }
                return byPath[request.url!.path] ?? PaperFetchReply(status: 404, data: Data("Not found".utf8))
            }
        }
    }

    private static let userID = 42
    private static let key = "TestKeyForPaperSources1"

    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return model
    }

    private func pdfBytes() throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            context.beginPage()
            ("Circadian rhythm and sleep: a readable paper for Spoken Margins." as NSString).draw(
                at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }

    private func items() -> Data {
        Data("""
        [
          {"key": "PDFPAPR1", "data": {"key": "PDFPAPR1", "itemType": "journalArticle", "title": "Sleep and the clock",
            "creators": [{"creatorType": "author", "firstName": "A", "lastName": "Smith"}], "publicationTitle": "Nature",
            "date": "2021", "DOI": "10.1000/sleep-clock", "dateAdded": "2026-11-20T10:00:00Z"}},
          {"key": "ABSPAPR1", "data": {"key": "ABSPAPR1", "itemType": "journalArticle", "title": "Light at night",
            "creators": [{"creatorType": "author", "firstName": "B", "lastName": "Jones"}], "publicationTitle": "Sleep",
            "date": "2019", "abstractNote": "We studied light at night.", "url": "https://example.org/light",
            "dateAdded": "2026-11-19T10:00:00Z"}}
        ]
        """.utf8)
    }

    private func attachments() -> Data {
        Data("""
        [{"key": "ATTACHP1", "data": {"key": "ATTACHP1", "itemType": "attachment", "parentItem": "PDFPAPR1",
          "linkMode": "imported_file", "contentType": "application/pdf", "title": "Full Text PDF"}}]
        """.utf8)
    }

    private func collectionsList() -> Data {
        Data("""
        [{"key": "READING1", "library": {"type": "user", "id": 42, "name": "testlistener"}, "meta": {"numItems": 2},
          "data": {"key": "READING1", "name": "PHIL 330 readings", "parentCollection": false}}]
        """.utf8)
    }

    func testFollowSeeTheRowAddAPDFAndAnAbstractAndBothAreInLibrary() async throws {
        let model = makeModel()
        let credentials = Credentials()
        let replies = Replies()
        let base = "/users/\(Self.userID)"
        replies.byPath["\(base)/collections"] = PaperFetchReply(status: 200, data: collectionsList())
        replies.byPath["\(base)/collections/READING1"] = PaperFetchReply(
            status: 200, data: Data(#"{"key": "READING1", "data": {"name": "PHIL 330 readings"}}"#.utf8))
        replies.byPath["\(base)/collections/READING1/items/top"] = PaperFetchReply(status: 200, data: items(), totalResults: 2)
        replies.byPath["\(base)/collections/READING1/items"] = PaperFetchReply(status: 200, data: attachments())
        replies.byPath["\(base)/items/ATTACHP1/file"] = PaperFetchReply(status: 200, data: try pdfBytes())
        let papers = PaperSourcesState(credentials: credentials.store, transport: replies.transport)

        // Settings › Zotero: a wrong ID is refused before any request; the right one connects and lists the collection.
        let refused = await papers.connect(userID: "", apiKey: Self.key)
        XCTAssertNotNil(refused)
        XCTAssertNil(papers.connection)
        let connected = await papers.connect(userID: "\(Self.userID)", apiKey: Self.key)
        XCTAssertNil(connected)
        XCTAssertEqual(papers.connection?.statusLine, "Connected as testlistener")
        XCTAssertEqual(papers.collections.map(\.name), ["PHIL 330 readings"])
        XCTAssertEqual(credentials.values["apiKey"], Self.key, "kept for the next launch")

        // Follow papers › Your collections.
        let followed = await papers.follow(collection: papers.collections.first, model: model)
        XCTAssertEqual(followed, .followed)
        let record = try XCTUnwrap(papers.records.first)
        XCTAssertEqual(record.title, "PHIL 330 readings")
        XCTAssertEqual(papers.visibleRows.map(\.detail), ["Zotero · 2 papers"])
        XCTAssertEqual(FollowingFeed.rows([], splicingPapers: papers.visibleRows, showsLoaded: true).map(\.id), ["papers::\(record.id)"])

        // The list's screen: one PDF paper (stored in the listener's library), one abstract paper.
        var index = await papers.libraryIndex(model: model)
        var rows = papers.rows(for: record, index: index)
        XCTAssertEqual(rows.map(\.statusTitle), ["PDF", "Abstract only"])
        XCTAssertEqual(rows.map(\.button), [.add, .add])

        let libraryBefore = model.libraryItems.count
        let playingBefore = model.snapshot.itemId
        await papers.add(rows[0].entry, model: model)
        await papers.add(rows[1].entry, model: model)
        index = await papers.libraryIndex(model: model)
        rows = papers.rows(for: record, index: index)
        guard case .inLibrary = rows[0].button, case .inLibrary(let abstractItemID) = rows[1].button else {
            return XCTFail("both papers should read In Library: \(rows.map(\.button))")
        }
        XCTAssertEqual(model.libraryItems.count, libraryBefore + 2)
        XCTAssertEqual(model.snapshot.itemId, playingBefore, "Add never starts playback")
        let abstractItem = try XCTUnwrap(model.store).loadItem(id: abstractItemID)
        XCTAssertEqual(abstractItem.sourceTitle, "Abstract · Zotero")
        XCTAssertTrue(abstractItem.text.contains("We studied light at night."))

        // Two taps import once.
        await papers.add(rows[1].entry, model: model)
        XCTAssertEqual(model.libraryItems.count, libraryBefore + 2)

        // The key went only to Zotero, in its header.
        XCTAssertFalse(replies.requests.isEmpty)
        for request in replies.requests {
            XCTAssertEqual(request.url?.host, "api.zotero.org")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Zotero-API-Key"), Self.key)
            XCTAssertFalse(request.url!.absoluteString.contains(Self.key))
        }
        XCTAssertFalse(model.diagnostics.values.contains { $0.contains(Self.key) }, "the key is never in Diagnostics")
        XCTAssertFalse(model.diagnostics.values.contains { $0.contains("/users/\(Self.userID)") }, "nor the user ID (#853)")
        guard case .inLibrary(let pdfItemID) = rows[0].button else { return XCTFail("PDF row") }
        let pdfItem = try XCTUnwrap(model.store).loadItem(id: pdfItemID)
        XCTAssertFalse((pdfItem.sourceURL ?? "").contains("api.zotero.org"), "kept under the paper's own address, never the API's")
        XCTAssertFalse((pdfItem.externalReference ?? "").contains("api.zotero.org"))

        // A key revoked on zotero.org: the list keeps its papers and its screen says why; offline says so too.
        replies.byPath["\(base)/collections/READING1/items/top"] = PaperFetchReply(status: 403, data: Data("Forbidden".utf8))
        await papers.refresh(model: model, pulled: true, only: record.id)
        XCTAssertEqual(papers.refreshProblemLine(id: record.id), "Zotero didn't accept that key.")
        XCTAssertEqual(papers.record(id: record.id)?.entries.count, 2, "the last papers stay")
        replies.byPath["\(base)/collections/READING1/items/top"] = nil
        replies.offline = true
        await papers.refresh(model: model, pulled: true, only: record.id)
        XCTAssertEqual(papers.refreshProblemLine(id: record.id), "Showing the last local snapshot")
        replies.offline = false

        // Unfollow leaves the papers in the Library; Disconnect forgets the key.
        await papers.unfollow(id: record.id, model: model, offerUndo: false)
        XCTAssertTrue(papers.records.isEmpty)
        XCTAssertEqual(model.libraryItems.count, libraryBefore + 2)
        papers.disconnect()
        XCTAssertNil(credentials.values["apiKey"])
        XCTAssertNil(papers.connection)
    }

    func testAPublicGroupLinkThatIsPrivateSaysSoAndFollowsNothing() async throws {
        let model = makeModel()
        let replies = Replies()
        replies.byPath["/groups/99/collections/ABCD2345/items/top"] = PaperFetchReply(status: 403, data: Data("Forbidden".utf8))
        let papers = PaperSourcesState(credentials: Credentials().store, transport: replies.transport)
        let result = await papers.follow(pasted: "https://www.zotero.org/groups/99/x/collections/ABCD2345", model: model)
        XCTAssertEqual(result, .problem("That Zotero library is private. Connect your library in Settings to follow it."))
        XCTAssertTrue(papers.records.isEmpty)
    }
}
