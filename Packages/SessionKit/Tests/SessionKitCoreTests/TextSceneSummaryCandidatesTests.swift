import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #3461: which item the charging pass writes scene summaries for, and what the item screen is told, on a real SQLite Library.
final class TextSceneSummaryCandidatesTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("text-scene-candidates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let body = "The caravans left the oasis before dawn and crossed the dunes in single file. Water was counted by the cup."

    private func article(_ id: String, withChapters: Bool = true) throws {
        try store.saveItem(Item(id: id, title: id, mediaType: "article", text: body, externalReference: nil, status: "ready"))
        if withChapters {
            try store.saveListeningMap(ListeningMap(id: "map-\(id)", itemId: id, overview: "", chapters: [
                Chapter(id: "ch-1", title: "One", startChar: 0, endChar: body.count, percent: 0)
            ]))
        }
    }

    private func scene(_ id: String, summary: String?, eligibility: PortableSceneEligibility) -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: id, order: 0, title: "T", summaryText: summary, summaryProvenance: summary == nil ? nil : .modelGenerated,
            eligibility: eligibility,
            startAnchor: PortableAnchorEvidence(anchorType: .text, startChar: 0, endChar: 5, exactText: "The c"),
            endAnchor: PortableAnchorEvidence(anchorType: .text, startChar: 5, endChar: 10, exactText: "aravan"))
    }

    private func saveModelProposal(_ itemId: String, _ scenes: [PortableListeningMapScene]) throws {
        try store.savePortableListeningMapProposal(
            TextSceneAssembly.proposal(safeItemComponent: itemId, scenes: scenes), itemId: itemId)
    }

    func testTheNextCandidateIsTheFirstTextItemWithChaptersAndNoSummaries() throws {
        try store.saveItem(Item(
            id: "ep", title: "ep", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "https://cdn.example.com/ep.mp3", durationMs: 1000), author: nil))
        try article("no-chapters", withChapters: false)
        try article("a")
        try article("b")

        XCTAssertEqual(
            TextSceneSummaryCandidates.next(itemIds: ["missing", "ep", "no-chapters", "a", "b"], settled: [], store: store), "a")
        XCTAssertEqual(TextSceneSummaryCandidates.next(itemIds: ["a", "b"], settled: ["a"], store: store), "b")
        XCTAssertNil(TextSceneSummaryCandidates.next(itemIds: ["ep", "no-chapters", "missing"], settled: [], store: store))
    }

    func testAnItemWithAStoppedRunIsACandidateAndAFinishedOneIsNot() throws {
        try article("stopped")
        try saveModelProposal("stopped", [scene("s1", summary: "How caravans crossed.", eligibility: .eligible), scene("s2", summary: nil, eligibility: .unknown)])
        try article("done")
        try saveModelProposal("done", [scene("s1", summary: "How caravans crossed.", eligibility: .eligible), scene("s2", summary: nil, eligibility: .excluded)])

        XCTAssertEqual(TextSceneSummaryCandidates.next(itemIds: ["done", "stopped"], settled: [], store: store), "stopped")
        XCTAssertNil(TextSceneSummaryCandidates.next(itemIds: ["done"], settled: [], store: store))
    }

    func testAFriendsMapKeepsTheItemOutOfTheBackgroundPass() throws {
        try article("shared")
        try store.savePortableListeningMapProposal(PortableListeningMapProposalArtifact(
            id: "friend", createdAt: Date(), generator: TextSceneAssembly.sharedGenerator,
            scenes: [scene("s1", summary: "Theirs.", eligibility: .eligible)]), itemId: "shared")

        XCTAssertNil(TextSceneSummaryCandidates.next(itemIds: ["shared"], settled: [], store: store))
    }

    func testTheItemScreenIsToldWhereTheSummariesStand() throws {
        try article("fresh")
        try article("half")
        try saveModelProposal("half", [scene("s1", summary: "How caravans crossed.", eligibility: .eligible), scene("s2", summary: nil, eligibility: .unknown)])
        try article("whole")
        try saveModelProposal("whole", [scene("s1", summary: "How caravans crossed.", eligibility: .eligible)])
        func state(_ id: String) throws -> TextSceneSummaryProgress.State {
            try ItemDetailLoader.load(id: id, store: store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses()).textSceneSummaries
        }

        XCTAssertEqual(try state("fresh"), .notStarted)
        XCTAssertEqual(try state("half"), .partial(decided: 1, total: 2))
        XCTAssertEqual(try state("whole"), .complete)
    }
}
