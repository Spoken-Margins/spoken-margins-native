import Foundation
import SessionKit
import XCTest

/// #3450: the proposal Skim reads on an article or PDF, and what of it may leave the device.
final class TextSceneAssemblyTests: XCTestCase {
    private let text = "The caravans left the oasis before dawn and crossed the dunes in single file. Water was counted by the cup. "
        + "At the coast the cargo was weighed, taxed and loaded onto narrow boats. Brokers argued over every sack of salt."

    private func drafts() -> [TextSceneDraft] {
        let chapters = [
            Chapter(id: "ch-generated-01", title: "The caravans left", startChar: 0, endChar: 108, percent: 0),
            Chapter(id: "ch-generated-02", title: "At the coast", startChar: 108, endChar: text.count, percent: 50),
        ]
        return TextSceneSummaryPlanner.plan(text: text, chapters: chapters)
    }

    private func label(eligibility: PortableSceneEligibility = .eligible) -> ListeningMapSummaryValidator.SceneLabel {
        ListeningMapSummaryValidator.SceneLabel(
            title: "Crossing the desert", description: "How caravans carried goods over the dunes.",
            eligibility: eligibility, eligibilityReason: "Editorial content.")
    }

    func testALabelledSceneIsPlacedByCharacterWithAQuotationAtEachEnd() {
        let characters = Array(text)
        let draft = drafts()[1]

        let scene = TextSceneAssembly.scene(draft: draft, label: label(), characters: characters)

        XCTAssertEqual(scene.id, "ch-generated-02")
        XCTAssertEqual(scene.order, 1)
        XCTAssertEqual(scene.title, "Crossing the desert")
        XCTAssertEqual(scene.summaryText, "How caravans carried goods over the dunes.")
        XCTAssertEqual(scene.summaryProvenance, .modelGenerated)
        XCTAssertEqual(scene.eligibility, .eligible)
        XCTAssertEqual(scene.startAnchor.anchorType, .text)
        XCTAssertEqual(scene.startAnchor.startChar, draft.startChar)
        XCTAssertEqual(scene.startAnchor.exactText, String(characters[draft.startChar..<(draft.startChar + 80)]))
        XCTAssertEqual(scene.startAnchor.prefix?.count, 40)
        XCTAssertEqual(scene.endAnchor.endChar, text.count)
        XCTAssertEqual(scene.endAnchor.exactText, String(characters[(text.count - 80)..<text.count]))
        XCTAssertNil(scene.endAnchor.suffix, "nothing follows the last scene")
    }

    func testASceneWithoutAnAcceptedLabelKeepsItsPlaceAndItsDeterministicTitleAndNoSummary() {
        let scene = TextSceneAssembly.scene(draft: drafts()[0], label: nil, characters: Array(text))

        XCTAssertEqual(scene.title, "The caravans left")
        XCTAssertNil(scene.summaryText)
        XCTAssertNil(scene.summaryProvenance)
        XCTAssertEqual(scene.eligibility, .unknown)
        XCTAssertEqual(scene.startAnchor.startChar, 0)
        XCTAssertNil(scene.startAnchor.prefix)
    }

    func testAnExcludedSceneKeepsNoSummary() {
        let scene = TextSceneAssembly.scene(draft: drafts()[0], label: label(eligibility: .excluded), characters: Array(text))

        XCTAssertNil(scene.summaryText)
        XCTAssertEqual(scene.eligibility, .excluded)
    }

    func testTheProposalMeetsThePortableMapRules() {
        let characters = Array(text)
        let scenes = drafts().map { TextSceneAssembly.scene(draft: $0, label: label(), characters: characters) }
        let proposal = TextSceneAssembly.proposal(safeItemComponent: "article", scenes: scenes)

        XCTAssertEqual(proposal.id, "text-scene-map-article")
        XCTAssertEqual(proposal.generator, "on-device-text-scene-map.v1")
        XCTAssertEqual(PortableListeningMapContract.violations(in: proposal, itemText: text), [])
        XCTAssertEqual(SceneStarts.textProposal(in: [proposal])?.id, proposal.id)
        XCTAssertEqual(SceneStarts(textScenes: proposal.scenes).sceneStarts, [0, 108])
    }

    func testTheProposalSurvivesAJSONRoundTripUnchanged() throws {
        let characters = Array(text)
        let scenes = drafts().map { TextSceneAssembly.scene(draft: $0, label: label(), characters: characters) }
        let proposal = TextSceneAssembly.proposal(safeItemComponent: "article", scenes: scenes, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(PortableListeningMapProposalArtifact.self, from: encoder.encode(proposal)), proposal)
    }

    func testCompletionStatusCountsTheScenesThatKeptASummary() {
        let characters = Array(text)
        let all = drafts()
        let one = [TextSceneAssembly.scene(draft: all[0], label: label(), characters: characters),
                   TextSceneAssembly.scene(draft: all[1], label: nil, characters: characters)]

        XCTAssertEqual(TextSceneAssembly.completionStatus(scenes: one), "Ready with scene summaries (1 of 2 scenes)")
        XCTAssertEqual(TextSceneAssembly.completionStatus(scenes: [one[1]]), "Ready with chapters")
    }
}

/// #3450 / #3449: an export of a text item never takes a chapter title from the model's scenes.
final class TextSceneExportTests: XCTestCase {
    func testAnExportOfAPDFHoldsTheRuleBasedChaptersAndNoModelWrittenTitle() throws {
        let text = "The caravans left the oasis before dawn and crossed the dunes in single file. Water was counted by the cup. "
            + "At the coast the cargo was weighed, taxed and loaded onto narrow boats. Brokers argued over every sack of salt."
        let item = Item(id: "pdf-1", title: "Salt roads", mediaType: "text", text: text, externalReference: nil, status: "ready",
                        externalReferenceType: "file")
        let repository = InMemorySessionRepository()
        try repository.saveItem(item)
        try repository.saveListeningMap(ListeningMap(id: "map-pdf-1-generated", itemId: item.id, overview: "", chapters: [
            Chapter(id: "ch-generated-01", title: "The caravans left the oasis", startChar: 0, endChar: 108, percent: 0),
            Chapter(id: "ch-generated-02", title: "At the coast the cargo", startChar: 108, endChar: text.count, percent: 50),
        ]))
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: try XCTUnwrap(repository.loadListeningMap(itemId: item.id)).chapters)
        let label = ListeningMapSummaryValidator.SceneLabel(
            title: "Crossing the desert", description: "How caravans carried goods over the dunes.",
            eligibility: .eligible, eligibilityReason: nil)
        try repository.savePortableListeningMapProposal(
            TextSceneAssembly.proposal(
                safeItemComponent: "pdf-1",
                scenes: drafts.map { TextSceneAssembly.scene(draft: $0, label: label, characters: Array(text)) }
            ),
            itemId: item.id
        )

        let exported = try XCTUnwrap(ListeningMapExportResolver.resolve(item: item, repository: repository, durationMs: nil))

        XCTAssertEqual(exported.chapters.map(\.title), ["The caravans left the oasis", "At the coast the cargo"])
        XCTAssertFalse(exported.chapters.contains { $0.title.contains("Crossing the desert") })
    }
}
