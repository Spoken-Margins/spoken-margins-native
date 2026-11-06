import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #3450: on-device scene summaries for an article or a PDF, run for real against a temporary SQLite library. Only the
/// model is scripted; the planner, the grounding check, the proposal and the save are the ones the app uses.
final class TextSceneMapPreparerTests: XCTestCase {
    private struct Fixture {
        let store: SQLiteSessionStore
        let itemId: String
        let text: String
    }

    private static let section1 = "The caravans left the oasis before dawn and crossed the dunes in single file. Water was counted by the cup. "
    private static let section2 = "At the coast the cargo was weighed, taxed and loaded onto narrow boats. Brokers argued over every sack of salt. "

    private func makeFixture(extraProposal: PortableListeningMapProposalArtifact? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "p3450-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path)
        let text = Self.section1 + Self.section2
        try store.saveItem(Item(id: "article", title: "Salt roads", mediaType: "text", text: text, externalReference: nil, status: "ready"))
        try store.saveListeningMap(ListeningMap(id: "map-article-generated", itemId: "article", overview: "", chapters: [
            Chapter(id: "ch-generated-01", title: "The caravans left", startChar: 0, endChar: Self.section1.count, percent: 0),
            Chapter(id: "ch-generated-02", title: "At the coast", startChar: Self.section1.count, endChar: text.count, percent: 50),
        ]))
        if let extraProposal { try store.savePortableListeningMapProposal(extraProposal, itemId: "article") }
        return Fixture(store: store, itemId: "article", text: text)
    }

    func testEachSceneGetsAGroundedSummaryAndTheMapIsSavedByCharacter() async throws {
        let fixture = try makeFixture()
        let rendered = RenderedBox()

        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store,
            client: ScriptedLabelClient(label: LocalListeningMapLabel(title: "Crossing the desert", description: "how the caravans carried goods across the dunes", eligibility: .eligible)),
            renderBridge: { scene, proposalId in rendered.add("\(proposalId)/\(scene.id)") }
        )

        XCTAssertEqual(outcome, .summarised(scenes: 2, total: 2))
        let proposal = try XCTUnwrap(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId).first)
        XCTAssertEqual(proposal.id, "text-scene-map-article")
        XCTAssertEqual(proposal.generator, TextSceneAssembly.generator)
        XCTAssertEqual(proposal.scenes.map(\.id), ["ch-generated-01", "ch-generated-02"])
        XCTAssertEqual(proposal.scenes.map { $0.startAnchor.startChar }, [0, Self.section1.count])
        XCTAssertTrue(proposal.scenes.allSatisfy { $0.summaryProvenance == .modelGenerated && $0.eligibility == .eligible })
        XCTAssertEqual(rendered.values, ["text-scene-map-article/ch-generated-01", "text-scene-map-article/ch-generated-02"])
        // Skim reads it by character, as it does an edition's (#1471).
        XCTAssertEqual(SceneStarts.textProposal(in: [proposal])?.id, proposal.id)
        XCTAssertEqual(SceneStarts(textScenes: proposal.scenes).sceneStarts, [0, Self.section1.count])
    }

    func testSummariesThatFailTheGroundingCheckLeaveTheChaptersAlone() async throws {
        let fixture = try makeFixture()

        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store,
            // "Berlin" and "1987" are in neither section.
            client: ScriptedLabelClient(label: LocalListeningMapLabel(title: "Berlin trade", description: "how Berlin traders met in 1987", eligibility: .eligible)),
            renderBridge: { _, _ in XCTFail("no summary, no audio") }
        )

        XCTAssertEqual(outcome, .noSummaryAccepted)
        XCTAssertEqual(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId), [])
        XCTAssertEqual(try fixture.store.loadListeningMap(itemId: fixture.itemId)?.chapters.count, 2)
    }

    func testAMapTheListenerAlreadyHasIsNotReplaced() async throws {
        let other = PortableListeningMapProposalArtifact(
            id: "shared-map", createdAt: Date(), generator: "sender", scenes: [PortableListeningMapScene(
                id: "s1", order: 0, title: "Theirs", eligibility: .unknown,
                startAnchor: PortableAnchorEvidence(anchorType: .text, startChar: 0, endChar: 5, exactText: "The c"),
                endAnchor: PortableAnchorEvidence(anchorType: .text, startChar: 5, endChar: 10, exactText: "aravan")
            )]
        )
        let fixture = try makeFixture(extraProposal: other)

        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store,
            client: ScriptedLabelClient(label: LocalListeningMapLabel(title: "Crossing", description: "how the caravans crossed the dunes", eligibility: .eligible)),
            renderBridge: { _, _ in XCTFail("nothing to render") }
        )

        XCTAssertEqual(outcome, .keptOtherMap)
        XCTAssertEqual(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId).map(\.id), ["shared-map"])
    }

    /// The audit on 946f910: a run takes minutes, and a friend's map imported meanwhile replaced the chapters the scenes
    /// were planned on, so the run must not save its scenes beside it.
    func testAFriendsMapImportedWhileTheRunWorksIsNotLeftWithOutOfDateScenesBesideIt() async throws {
        let fixture = try makeFixture()
        let theirs = PortableListeningMapProposalArtifact(
            id: "shared-map", createdAt: Date(), generator: "sender", scenes: [PortableListeningMapScene(
                id: "s1", order: 0, title: "Theirs", eligibility: .unknown,
                startAnchor: PortableAnchorEvidence(anchorType: .text, startChar: 0, endChar: 5, exactText: "The c"),
                endAnchor: PortableAnchorEvidence(anchorType: .text, startChar: 5, endChar: 10, exactText: "aravan")
            )]
        )
        let client = ScriptedLabelClient(label: LocalListeningMapLabel(title: "Crossing", description: "how the caravans crossed the dunes", eligibility: .eligible))
        client.onLabel = {
            try? fixture.store.saveListeningMap(ListeningMap(id: "shared-map-article", itemId: "article", overview: "", chapters: [
                Chapter(id: "theirs-1", title: "Theirs", startChar: 0, endChar: fixture.text.count, percent: 0)
            ]))
            try? fixture.store.savePortableListeningMapProposal(theirs, itemId: "article")
        }

        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store, client: client,
            renderBridge: { _, _ in XCTFail("nothing was saved, so nothing to render") }
        )

        XCTAssertEqual(outcome, .keptOtherMap)
        XCTAssertEqual(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId).map(\.id), ["shared-map"])
    }

    /// #3461: heat stops the run between scenes, the first scene's summary is already saved, and the next run asks the
    /// model only about the scene that is still missing.
    func testARunPausedForHeatKeepsItsSummariesAndTheNextRunContinues() async throws {
        let fixture = try makeFixture()
        let label = LocalListeningMapLabel(title: "Crossing", description: "how the caravans crossed the dunes", eligibility: .eligible)
        let asked = CountBox()

        let paused = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store,
            client: ScriptedLabelClient(label: label),
            yieldReason: { asked.next() == 2 ? .heat(.serious) : nil },
            renderBridge: { _, _ in XCTFail("a paused run renders nothing") }
        )

        XCTAssertEqual(paused, .paused(.heat(.serious), written: 1, total: 2))
        let saved = try XCTUnwrap(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId).first)
        XCTAssertEqual(saved.scenes.filter { $0.summaryText?.isEmpty == false }.map(\.id), ["ch-generated-01"])

        let second = ScriptedLabelClient(label: label)
        let finished = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store, client: second, renderBridge: { _, _ in }
        )

        XCTAssertEqual(finished, .summarised(scenes: 2, total: 2))
        XCTAssertEqual(second.texts, [Self.section2.trimmingCharacters(in: .whitespaces)], "the scene already written is not asked again")
        let done = try XCTUnwrap(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId).first)
        XCTAssertEqual(TextSceneSummaryProgress.state(proposals: [done]), .complete)
    }

    /// #3461: an item that already has chapters and no scene summaries (made before #3450, or after "model unavailable")
    /// gets them from the same step the first run uses.
    func testAnItemThatAlreadyHasChaptersGetsItsSummariesFromAFreshRun() async throws {
        let fixture = try makeFixture()
        let detail = try ItemDetailLoader.load(
            id: fixture.itemId, store: fixture.store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses())
        XCTAssertEqual(detail.textSceneSummaries, .notStarted)
        XCTAssertEqual(detail.chapters.count, 2)

        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store,
            client: ScriptedLabelClient(label: LocalListeningMapLabel(title: "Crossing", description: "how the caravans crossed the dunes", eligibility: .eligible)),
            renderBridge: { _, _ in }
        )

        XCTAssertEqual(outcome, .summarised(scenes: 2, total: 2))
        let after = try ItemDetailLoader.load(
            id: fixture.itemId, store: fixture.store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses())
        XCTAssertEqual(after.textSceneSummaries, .complete)
    }

    /// An older build saved a friend's proposal under this device's generator; beside their Listening Map it is theirs.
    func testAFriendsProposalFromAnOlderBuildUnderTheDevicesGeneratorIsNotContinuedOrWrittenOver() async throws {
        let fixture = try makeFixture()
        try fixture.store.saveListeningMap(ListeningMap(id: "shared-map-article", itemId: "article", overview: "", chapters: [
            Chapter(id: "theirs-1", title: "Theirs", startChar: 0, endChar: fixture.text.count, percent: 0)
        ]))
        try fixture.store.savePortableListeningMapProposal(TextSceneAssembly.proposal(safeItemComponent: "friend", scenes: []), itemId: "article")

        let outcome = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store,
            client: ScriptedLabelClient(label: LocalListeningMapLabel(title: "Crossing", description: "how the caravans crossed the dunes", eligibility: .eligible)),
            renderBridge: { _, _ in XCTFail("nothing to render") }
        )

        XCTAssertEqual(outcome, .keptOtherMap)
        XCTAssertEqual(try fixture.store.loadPortableListeningMapProposals(itemId: fixture.itemId).map(\.id), ["text-scene-map-friend"])
    }

    func testARunOnlyLooksAtTheListenersOwnText() async throws {
        // The planner and the model read the item's stored text; nothing is fetched, so a run works offline.
        let fixture = try makeFixture()
        let client = ScriptedLabelClient(label: LocalListeningMapLabel(title: "Crossing", description: "how the caravans crossed the dunes", eligibility: .eligible))

        _ = try await TextSceneMapPreparer.summarise(
            itemId: fixture.itemId, safeItemComponent: "article", store: fixture.store, client: client, renderBridge: { _, _ in }
        )

        XCTAssertEqual(client.texts, [Self.section1.trimmingCharacters(in: .whitespaces), Self.section2.trimmingCharacters(in: .whitespaces)])
    }
}

private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private final class RenderedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ value: String) { lock.withLock { items.append(value) } }
    var values: [String] { lock.withLock { items } }
}

private final class ScriptedLabelClient: LocalFoundationModelClient, @unchecked Sendable {
    private let label: LocalListeningMapLabel
    private let lock = NSLock()
    private var seen: [String] = []

    init(label: LocalListeningMapLabel) { self.label = label }

    var texts: [String] { lock.withLock { seen } }
    /// Called on each model call, to let a test change the library while the run is working.
    var onLabel: (@Sendable () -> Void)?

    func availability() -> LocalFoundationModelAvailability { .available }
    func summarizeInterjections(context: String) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        lock.withLock { seen.append(text) }
        onLabel?()
        return label
    }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
}
