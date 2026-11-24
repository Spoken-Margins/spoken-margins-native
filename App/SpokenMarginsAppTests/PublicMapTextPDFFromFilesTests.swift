@testable import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #3449 Done when 5, on the app's real model and a temporary SQLite library: a PDF from Files gets on-device scene
/// summaries with no network check, Skim reads them by character, and the Share Margins review says in plain words that
/// the summaries stay on the phone, with the count of scenes held back. A probe that records every request stands in for
/// the network. A control item from a web address, checked through the same marker, shows the probe is wired: it makes
/// one request, so the PDF's zero is not a probe that cannot be reached.
@MainActor
final class PublicMapTextPDFFromFilesTests: XCTestCase {
    private final class CountingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var requests: [String] { lock.withLock { seen } }
        var probe: PublicSourceVerifier.Probe {
            { [self] url, _ in
                lock.withLock { seen.append(url.absoluteString) }
                return PublicSourceVerifier.Response(status: 200, contentType: "text/html", body: Data("<p>nothing</p>".utf8))
            }
        }
    }

    private final class OneLabelClient: LocalFoundationModelClient, @unchecked Sendable {
        func availability() -> LocalFoundationModelAvailability { .available }
        func summarizeInterjections(context: String) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
        func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
            LocalListeningMapLabel(title: "Crossing the desert", description: "how the caravans carried goods across the dunes", eligibility: .eligible)
        }
        func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
    }

    private static let section1 = "The caravans left the oasis before dawn and crossed the dunes in single file. Water was counted by the cup. "
    private static let section2 = "At the coast the cargo was weighed, taxed and loaded onto narrow boats. Brokers argued over every sack of salt. "

    /// Four sentences of eight words or more: enough for the check to sample, so it makes its request.
    private static let controlText = "The caravans left the oasis before dawn and crossed the dunes in single file. "
        + "At the coast the cargo was weighed, taxed and loaded onto narrow boats by the harbour clerks. "
        + "Brokers argued over every sack of salt until the evening bell rang across the harbour. "
        + "The boats sailed north with the tide and returned only when the winter storms had passed."

    func testAPDFFromFilesGetsSummariesWithNoNetworkCheckSkimReadsThemAndTheShareReviewSaysTheyStayHome() async throws {
        let counting = CountingProbe()
        let previousMarker = PublicSourceChecks.marker
        PublicSourceChecks.marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: counting.probe))
        defer { PublicSourceChecks.marker = previousMarker }

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let store = try XCTUnwrap(model.store)

        // 1. The model summarises the PDF on the phone. No mark is needed for that, and nothing is fetched.
        let (pdf, outcome) = try await Self.seedSummarisedPDF(store: store)
        let itemId = pdf.id
        XCTAssertEqual(pdf.externalReferenceType, "file", "a file from Files: no public copy to check")
        let text = try XCTUnwrap(pdf.text)
        let secondStart = try XCTUnwrap(text.range(of: "At the coast").map { text.distance(from: text.startIndex, to: $0.lowerBound) })
        XCTAssertEqual(outcome, .summarised(scenes: 2, total: 2))
        let proposals = try store.loadPortableListeningMapProposals(itemId: itemId)
        let proposal = try XCTUnwrap(proposals.first)
        XCTAssertTrue(proposal.scenes.allSatisfy { $0.summaryProvenance == .modelGenerated && $0.summaryText?.isEmpty == false })

        // 2. Skim reads them: the text map is placed by character and the plan names the scene being summarised.
        let starts = SceneStarts(textScenes: proposal.scenes)
        XCTAssertEqual(SceneStarts.textProposal(in: proposals)?.id, proposal.id)
        XCTAssertEqual(starts.sceneStarts, [0, secondStart])
        let plan = try XCTUnwrap(starts.textSkimPlan(direction: .forward, at: 1))
        XCTAssertEqual(plan.summaryScene.id, "ch-generated-01")
        XCTAssertEqual(plan.summaryScene.summaryText?.isEmpty, false)

        // 3. The share review says the summaries stay here, and counts the scenes the packet holds back.
        model.selectedItem = ItemDetailState(id: itemId, title: pdf.title)
        await model.refreshWithheldMapNote(store: store)
        XCTAssertEqual(model.sharingState.withheldMapSceneCount, 2)
        let note = try XCTUnwrap(MapTextDisclosure.withheldNote(sceneCount: model.sharingState.withheldMapSceneCount))
        XCTAssertTrue(note.hasPrefix("Listening Map titles and summaries for 2 scenes won't be sent"), note)
        XCTAssertTrue(note.contains("2 scenes"), note)

        XCTAssertEqual(counting.requests, [], "summaries, Skim and the share review made no request to any publisher")
        XCTAssertNil(try store.loadItem(id: itemId).publicSourceMark)

        // Control: an article added from a web address, checked through the same marker, does reach the probe once.
        try store.saveItem(Item(id: "web-3449", title: "Article", mediaType: "text", text: Self.controlText,
                                externalReference: "https://example.com/salt-roads", status: "ready", externalReferenceType: "url"))
        _ = await PublicSourceChecks.ensureMark(itemId: "web-3449", store: store)
        XCTAssertEqual(counting.requests, ["https://example.com/salt-roads"], "the probe is wired; the PDF made no request")
        XCTAssertNil(try store.loadItem(id: "web-3449").publicSourceMark, "a page that is not this article earns no mark")
    }

    // MARK: The Share sheet's note (#4635)

    /// Done when 1 and 3: opening the live Share sheet counts the scenes that stay home, with no request for a PDF.
    func testOpeningTheShareSheetCountsTheScenesThatStayHome() async throws {
        let counting = CountingProbe()
        let previousMarker = PublicSourceChecks.marker
        PublicSourceChecks.marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: counting.probe))
        defer { PublicSourceChecks.marker = previousMarker }
        let (model, store) = Self.makeModel()
        let (pdf, _) = try await Self.seedSummarisedPDF(store: store)
        Self.select(pdf, on: model)

        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        await coordinator.withheldNoteTask?.value

        XCTAssertEqual(model.sharingState.withheldMapSceneCount, 2)
        XCTAssertEqual(coordinator.snapshot.withheldMapSceneCount, 2)
        XCTAssertEqual(counting.requests, [], "a PDF from Files has no public copy to check")
        XCTAssertNil(try store.loadItem(id: pdf.id).publicSourceMark)
    }

    /// A source already marked public withholds nothing: no note, and no request.
    func testAFreshPublicMarkShowsNoNoteAndMakesNoRequest() async throws {
        let counting = CountingProbe()
        let previousMarker = PublicSourceChecks.marker
        PublicSourceChecks.marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: counting.probe))
        defer { PublicSourceChecks.marker = previousMarker }
        let (model, store) = Self.makeModel()
        var web = try await Self.seedSummarisedWebItem(store: store)
        web.publicSourceMark = PublicSourceMark(url: try XCTUnwrap(MapTextDisclosure.checkableAddress(of: web)), checkedAt: Date())
        try store.saveItem(web)
        Self.select(web, on: model)

        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        await coordinator.withheldNoteTask?.value

        XCTAssertEqual(model.sharingState.withheldMapSceneCount, 0)
        XCTAssertEqual(coordinator.snapshot.withheldMapSceneCount, 0)
        XCTAssertEqual(counting.requests, [], "a fresh mark needs no check")
    }

    /// Cancel and reopen on another item: only the new item's count is shown.
    func testReopeningOnAnotherItemKeepsOnlyTheNewCount() async throws {
        let counting = CountingProbe()
        let previousMarker = PublicSourceChecks.marker
        PublicSourceChecks.marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: counting.probe))
        defer { PublicSourceChecks.marker = previousMarker }
        let (model, store) = Self.makeModel()
        let (pdf, _) = try await Self.seedSummarisedPDF(store: store)
        let plain = Item(id: "plain-4635", title: "Plain notes", mediaType: "text", text: Self.controlText,
                         externalReference: nil, status: "ready", externalReferenceType: "file")
        try store.saveItem(plain)

        Self.select(pdf, on: model)
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.cancel)
        Self.select(plain, on: model)
        coordinator.send(.begin)
        await coordinator.withheldNoteTask?.value

        XCTAssertEqual(model.sharingState.withheldMapSceneCount, 0)
        XCTAssertEqual(coordinator.snapshot.withheldMapSceneCount, 0)
    }

    /// The reply sheet is the same sheet, so it counts too.
    func testTheReplySheetCountsToo() async throws {
        let counting = CountingProbe()
        let previousMarker = PublicSourceChecks.marker
        PublicSourceChecks.marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: counting.probe))
        defer { PublicSourceChecks.marker = previousMarker }
        let (model, store) = Self.makeModel()
        let (pdf, _) = try await Self.seedSummarisedPDF(store: store)
        Self.select(pdf, on: model)

        let coordinator = Build23SharingCoordinator(model: model)
        model.presentReplyBackShare(ReplyBackOffer(replies: model.selectedItem.interjections, others: [], friendLabels: ["Cole"]))
        coordinator.send(.begin)
        await coordinator.withheldNoteTask?.value

        XCTAssertEqual(model.sharingState.withheldMapSceneCount, 2)
        XCTAssertTrue(coordinator.snapshot.isReplyBack)
        XCTAssertEqual(coordinator.snapshot.withheldMapSceneCount, 2)
    }

    /// After the packet's own check earns a mark, the recount the build runs clears the note without a second request.
    func testBuildingThePacketRecountsWithoutARequest() async throws {
        let counting = CountingProbe()
        let previousMarker = PublicSourceChecks.marker
        PublicSourceChecks.marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: counting.probe))
        defer { PublicSourceChecks.marker = previousMarker }
        let (model, store) = Self.makeModel()
        var web = try await Self.seedSummarisedWebItem(store: store)
        Self.select(web, on: model)

        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        await coordinator.withheldNoteTask?.value
        XCTAssertGreaterThan(model.sharingState.withheldMapSceneCount, 0, "a page that is not this article earns no mark")
        XCTAssertEqual(counting.requests.count, 1, "something would be withheld, so the check ran once")
        let requestsAfterOpen = counting.requests.count

        // The packet's own check earned the mark.
        web.publicSourceMark = PublicSourceMark(url: try XCTUnwrap(MapTextDisclosure.checkableAddress(of: web)), checkedAt: Date())
        try store.saveItem(web)
        await model.recountWithheldMapNote(store: try model.requireStore(), itemId: web.id)

        XCTAssertEqual(model.sharingState.withheldMapSceneCount, 0)
        XCTAssertEqual(coordinator.snapshot.withheldMapSceneCount, 0)
        XCTAssertEqual(counting.requests.count, requestsAfterOpen, "the recount makes no request")
    }

    // MARK: Helpers

    private static func makeModel() -> (Gate1AppModel, SQLiteSessionStore) {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        return (model, model.store!)
    }

    /// The PDF from Files with two model-written scenes, prepared the way Add from Files and the on-device model do.
    private static func seedSummarisedPDF(store: SQLiteSessionStore) async throws -> (Item, TextSceneSummaryOutcome) {
        // The picked PDF becomes an item through the same builder Add from Files uses; its origin is "file" on every branch.
        let prepared = try SourceFileItemBuilder.prepare(
            ImportedSourceText(text: section1 + "\n\n" + section2, documentStructure: nil, title: "Salt roads"),
            fileURL: URL(fileURLWithPath: "/private/var/mobile/Salt roads.pdf"), itemId: "pdf-3449", createdAt: Date())
        let itemId = prepared.item.id
        let text = try XCTUnwrap(prepared.item.text)
        let secondStart = try XCTUnwrap(text.range(of: "At the coast").map { text.distance(from: text.startIndex, to: $0.lowerBound) })
        try store.saveItem(prepared.item)
        try store.saveListeningMap(ListeningMap(id: "map-pdf-3449", itemId: itemId, overview: "", chapters: [
            Chapter(id: "ch-generated-01", title: "The caravans left", startChar: 0, endChar: secondStart, percent: 0),
            Chapter(id: "ch-generated-02", title: "At the coast", startChar: secondStart, endChar: text.count, percent: 50),
        ]))
        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: itemId, safeItemComponent: "pdf-3449", store: store, client: OneLabelClient(), renderBridge: { _, _ in })
        return (prepared.item, outcome)
    }

    /// An article from a web address with one model-written scene and no mark.
    private static func seedSummarisedWebItem(store: SQLiteSessionStore) async throws -> Item {
        let item = Item(id: "web-4635", title: "Article", mediaType: "text", text: controlText,
                        externalReference: "https://example.com/salt-roads", status: "ready", externalReferenceType: "url")
        try store.saveItem(item)
        try store.saveListeningMap(ListeningMap(id: "map-web-4635", itemId: item.id, overview: "", chapters: [
            Chapter(id: "ch-generated-01", title: "The caravans left", startChar: 0, endChar: controlText.count, percent: 0),
        ]))
        _ = try await TextSceneMapPreparer.summarise(
            itemId: item.id, safeItemComponent: "web-4635", store: store, client: OneLabelClient(), renderBridge: { _, _ in })
        return try store.loadItem(id: item.id)
    }

    /// Selects the item with one Margin of the listener's, so the Share sheet has something to share.
    private static func select(_ item: Item, on model: Gate1AppModel) {
        model.selectedItem = ItemDetailState(id: item.id, title: item.title)
        model.selectedItem.interjections = [Interjection(
            id: "margin-\(item.id)",
            itemId: item.id,
            sessionId: "session-4635",
            targetType: .item,
            targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 20,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "Reviewed Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
    }
}
