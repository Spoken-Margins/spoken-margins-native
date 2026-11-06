import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #3449 Done when 5, on the app's real model and a temporary SQLite library: a PDF from Files gets on-device scene
/// summaries with no network check, Skim reads them by character, and the Share Margins review says in plain words that
/// the summaries stay on the phone, with the count of scenes held back. A probe that records every request stands in for
/// the network; the test fails if the check ever reaches it.
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

    func testAPDFFromFilesGetsSummariesWithNoNetworkCheckSkimReadsThemAndTheShareReviewSaysTheyStayHome() async throws {
        let counting = CountingProbe()
        let previousMarker = PublicSourceChecks.marker
        PublicSourceChecks.marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: counting.probe))
        addTeardownBlock { @MainActor in PublicSourceChecks.marker = previousMarker }

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let store = try XCTUnwrap(model.store)

        // The picked PDF becomes an item exactly as Add from Files builds it.
        let prepared = try SourceFileItemBuilder.prepare(
            ImportedSourceText(text: Self.section1 + "\n\n" + Self.section2, documentStructure: nil, title: "Salt roads"),
            fileURL: URL(fileURLWithPath: "/private/var/mobile/Salt roads.pdf"), itemId: "pdf-3449", createdAt: Date())
        let itemId = prepared.item.id
        XCTAssertEqual(prepared.item.externalReferenceType, "file", "a file from Files: no public copy to check")
        let text = try XCTUnwrap(prepared.item.text)
        let secondStart = try XCTUnwrap(text.range(of: "At the coast").map { text.distance(from: text.startIndex, to: $0.lowerBound) })
        try store.saveItem(prepared.item)
        try store.saveListeningMap(ListeningMap(id: "map-pdf-3449", itemId: itemId, overview: "", chapters: [
            Chapter(id: "ch-generated-01", title: "The caravans left", startChar: 0, endChar: secondStart, percent: 0),
            Chapter(id: "ch-generated-02", title: "At the coast", startChar: secondStart, endChar: text.count, percent: 50),
        ]))

        // 1. The model summarises the PDF on the phone. No mark is needed for that, and nothing is fetched.
        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: itemId, safeItemComponent: "pdf-3449", store: store, client: OneLabelClient(), renderBridge: { _, _ in })
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
        model.selectedItem = ItemDetailState(id: itemId, title: prepared.item.title)
        await model.refreshWithheldMapNote()
        XCTAssertEqual(model.sharingState.withheldMapSceneCount, 2)
        let note = try XCTUnwrap(MapTextDisclosure.withheldNote(sceneCount: model.sharingState.withheldMapSceneCount))
        XCTAssertTrue(note.hasPrefix("Scene summaries stay on this phone."), note)
        XCTAssertTrue(note.contains("2 scenes"), note)

        XCTAssertEqual(counting.requests, [], "summaries, Skim and the share review made no request to any publisher")
        XCTAssertNil(try store.loadItem(id: itemId).publicSourceMark)
    }
}
