import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// Card D and sheet E on a real model (#4675, `docs/design/reply-mailbox.md` piece 8): a report hides the answer through
/// the Hide-this-Margin store and, with the toggle on, closes the box; a close that fails doesn't undo the report. The
/// club routes are a stand-in; the store, the record and the hide are real.
@MainActor
final class ReplyBoxCoordinatorTests: XCTestCase {
    private static let layerId = "layer-reply-box-answer"
    private static let marginId = "margin-reply-box-answer"

    final class Routes: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: (Int, String)] = [:]
        private var offline: Set<String> = []
        private(set) var paths: [String] = []

        func answer(_ route: String, _ status: Int, _ body: String = "{}") { lock.withLock { answers[route] = (status, body) } }
        func goOffline(_ route: String) { lock.withLock { _ = offline.insert(route) } }

        var send: ClubClient.Send {
            { [self] request, _ in
                try lock.withLock {
                    paths.append(request.path)
                    let route = request.path.split(separator: "/").suffix(from: 4).joined(separator: "/")
                    if offline.contains(route) { throw URLError(.notConnectedToInternet) }
                    let (status, body) = answers[route] ?? (500, #"{"error":"internal"}"#)
                    return (status, Data(body.utf8))
                }
            }
        }
    }

    private var model: Gate1AppModel!

    override func tearDown() async throws {
        model?.showMargin(Self.marginId) // the hide store lives in Application Support; leave it as found
        model = nil
        try await super.tearDown()
    }

    /// A model with a friend's answer on an item and the reply box it came through.
    private func makeModel(routes: Routes) throws -> (Gate1AppModel, SQLiteSessionStore, ReplyBoxRecord) {
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("reply-box-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: database) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        self.model = model
        let store = try model.requireStore()
        let date = Date(timeIntervalSince1970: 1_777_000_000)
        try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
            id: Self.layerId, itemId: nil, packageDigest: "digest-answer", packageId: "package-answer",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "Essay"), displayLabel: "Ana", importedAt: date))
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: Self.marginId, layerId: Self.layerId, packageScopedId: "margin-001", createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text, exactText: "quiet mornings"),
            approvedTranscript: "An answer through the link"))
        let record = ReplyBoxRecord(
            box: .random(), linkId: String(repeating: "b", count: 32), itemId: "item-shared", sharedPackageDigest: "sha256:shared",
            createdAt: date, expiresAt: Date().addingTimeInterval(30 * 86_400), cursor: 1,
            answers: [.init(seq: 1, layerId: Self.layerId)])
        try store.saveReplyBox(record)
        model.replyBoxes.send = routes.send
        return (model, store, record)
    }

    /// The sheet's own steps: choose, send, and the completion the sheet closes with.
    private func reportThroughTheSheet(_ model: Gate1AppModel, record: ReplyBoxRecord) async throws -> ReplyReportForm.Completion {
        var form = ReplyReportForm()
        form.category = .harassment
        XCTAssertTrue(form.alsoStop, "on by default")
        XCTAssertNotNil(form.beginSending())
        let result = await model.replyBoxes.report(
            boxId: record.boxId, seq: 1, category: .harassment, reason: form.trimmedReason, alsoStop: form.alsoStop)
        let completion = try XCTUnwrap(form.finishReport(result), "the sheet closes")
        await model.replyBoxes.finishReport(completion, layerId: Self.layerId)
        return completion
    }

    func testCardDFindsOnlyTheAnswerThatCameThroughTheBox() async throws {
        let (model, _, record) = try makeModel(routes: Routes())
        model.replyBoxes.loadRecordsIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.replyBoxes.records.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(model.replyBoxes.answer(carrying: Self.layerId)?.record.boxId, record.boxId)
        XCTAssertEqual(model.replyBoxes.answer(carrying: Self.layerId)?.seq, 1)
        XCTAssertNil(model.replyBoxes.answer(carrying: "layer-from-a-file"))
    }

    func testReportWithTheToggleHidesTheAnswerAndClosesTheBox() async throws {
        let routes = Routes()
        routes.answer("report", 200, #"{"filed":true,"reasonOutstanding":false,"ref":"R-1"}"#)
        routes.answer("close", 204)
        let (model, store, record) = try makeModel(routes: routes)

        let completion = try await reportThroughTheSheet(model, record: record)

        XCTAssertEqual(completion.banner, "Report sent. Reference R-1.")
        XCTAssertEqual(routes.paths.map { String($0.split(separator: "/").last!) }, ["report", "close"])
        XCTAssertTrue(model.hiddenSenders.isMarginHidden(Self.marginId), "hidden through the Hide-this-Margin store")
        XCTAssertEqual(try store.loadReplyBox(id: record.boxId)?.closed, true, "answers through the link are stopped")
    }

    func testAFailingCloseStillReports() async throws {
        let routes = Routes()
        routes.answer("report", 200, #"{"filed":true,"reasonOutstanding":false,"ref":"R-2"}"#)
        routes.goOffline("close")
        let (model, store, record) = try makeModel(routes: routes)

        let completion = try await reportThroughTheSheet(model, record: record)

        XCTAssertEqual(completion.banner, "Report sent. Reference R-2. Couldn't stop answers. Try again from the card.")
        XCTAssertTrue(model.hiddenSenders.isMarginHidden(Self.marginId), "the report stands, so the answer is hidden")
        XCTAssertEqual(try store.loadReplyBox(id: record.boxId)?.closed, false, "the box is still open, for a retry from the card")
    }
}
