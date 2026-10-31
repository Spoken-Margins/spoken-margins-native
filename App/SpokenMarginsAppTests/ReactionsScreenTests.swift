import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #476: "Where people reacted" reads the same chosen layers for its list and for the model, keeps a
/// summary only when it cites real Margins, and keeps it out of every export.
@MainActor
final class ReactionsScreenTests: XCTestCase {
    private let itemId = "item-reactions"
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    func testUncheckingALayerRemovesItsMarginsFromTheListAndFromTheModelInput() async throws {
        let item = itemWithThreeSenders()
        var selection = ReactionsSelection()
        XCTAssertEqual(ReactionsSelection.choices(for: item).map(\.label), ["Ana", "Ben", "Your Margins"])
        XCTAssertEqual(selection.input(for: item).placed.count, 4, "every enabled layer is chosen by default")

        selection.set("ben", chosen: false)
        let input = selection.input(for: item)
        XCTAssertEqual(input.placed.map(\.senderLabel), ["Ana", "you", "Ana"])
        XCTAssertFalse(MarginLayerSynthesis.hotSpots(input).flatMap(\.entries).contains { $0.approvedTranscript == "BEN-SAID-THIS" })

        let client = RecordingReactionsClient(reply: "Ana reacted. [m1]")
        let generator = ReactionSummaryGenerator(client: client, store: ReactionSummaryStore(directory: try temporaryDirectory()))
        _ = try await generator.generate(input: input)
        let prompt = try XCTUnwrap(client.prompts.first)
        XCTAssertFalse(prompt.contains("BEN-SAID-THIS"), "an unchecked layer reached the model")
        XCTAssertTrue(prompt.contains("ANA-SAID-THIS"))

        selection.set("__you__", chosen: false)
        XCTAssertEqual(selection.input(for: item).placed.map(\.senderLabel), ["Ana", "Ana"])
        selection.set("ben", chosen: true)
        XCTAssertEqual(selection.input(for: item).placed.count, 3)
    }

    func testTheSummaryIsKeptWithItsProvenanceAndReplacedOnTheNextRun() async throws {
        let item = itemWithThreeSenders()
        let store = ReactionSummaryStore(directory: try temporaryDirectory())
        let input = ReactionsSelection().input(for: item)

        let first = ReactionSummaryGenerator(client: RecordingReactionsClient(reply: "Ana and Ben disagreed. [m1][m2]"), store: store)
        let written = try await first.generate(input: input, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.load(itemId: itemId), written)
        XCTAssertEqual(written.provenance.modelId, ReactionSummaryGenerator.modelId)
        XCTAssertEqual(written.provenance.promptVersion, MarginLayerSynthesis.promptVersion)
        XCTAssertEqual(written.provenance.inputDigest, try input.digest())
        XCTAssertFalse(written.isStale(for: input))

        let second = ReactionSummaryGenerator(client: RecordingReactionsClient(reply: "Only Ana spoke. [m1]"), store: store)
        let replaced = try await second.generate(input: input, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.load(itemId: itemId)?.claims.map(\.text), ["Only Ana spoke."])
        XCTAssertEqual(store.load(itemId: itemId), replaced)
    }

    func testOnlyClaimsThatCiteRealMarginsAreKept() async throws {
        let item = itemWithThreeSenders()
        let store = ReactionSummaryStore(directory: try temporaryDirectory())
        let input = ReactionsSelection().input(for: item)
        let reply = "Ana made a point. [m1]\nCy agreed. [m1][m99]\nEveryone loved it."
        let summary = try await ReactionSummaryGenerator(client: RecordingReactionsClient(reply: reply), store: store).generate(input: input)
        XCTAssertEqual(summary.claims.map(\.text), ["Ana made a point."])

        let uncited = ReactionSummaryGenerator(client: RecordingReactionsClient(reply: "Everyone loved it."), store: ReactionSummaryStore(directory: try temporaryDirectory()))
        do {
            _ = try await uncited.generate(input: input)
            XCTFail("a summary that cites nothing was kept")
        } catch {
            XCTAssertEqual(error as? ReactionSummaryError, .nothingCited)
        }
        XCTAssertNil(uncited.store.load(itemId: itemId), "nothing is stored when no claim cites a Margin")
    }

    func testWhenTheModelIsUnavailableNothingRunsOrIsStored() async throws {
        let client = RecordingReactionsClient(reply: "Ana reacted. [m1]", availability: .unavailable("Turn on Apple Intelligence"))
        let store = ReactionSummaryStore(directory: try temporaryDirectory())
        do {
            _ = try await ReactionSummaryGenerator(client: client, store: store).generate(input: ReactionsSelection().input(for: itemWithThreeSenders()))
            XCTFail("the unavailable model ran")
        } catch {
            XCTAssertEqual(error as? LocalFoundationModelError, .unavailable("Turn on Apple Intelligence"))
        }
        XCTAssertTrue(client.prompts.isEmpty)
        XCTAssertNil(store.load(itemId: itemId))
    }

    func testAStoredSummaryNeverAppearsInTheSessionExport() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let directory = try model.applicationSupportDirectory().appendingPathComponent("ReactionSummaries", isDirectory: true)
        let store = ReactionSummaryStore(directory: directory)
        defer { store.delete(itemId: "item-pill") }

        let input = ReactionsSelection().input(for: itemWithThreeSenders(id: "item-pill"))
        _ = try await ReactionSummaryGenerator(client: RecordingReactionsClient(reply: "GENERATED-CLAIM-TEXT. [m1]"), store: store).generate(input: input)
        XCTAssertNotNil(store.load(itemId: "item-pill"))

        model.openExport()
        await model.buildExport()?.value // the preview's reads run off the main thread (#2505)
        XCTAssertFalse(model.exportPreview.isEmpty)
        XCTAssertFalse(model.exportPreview.contains("GENERATED-CLAIM-TEXT"))
        XCTAssertFalse(model.exportPreview.contains(MarginLayerSynthesis.promptVersion))
    }

    // MARK: Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reactions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func itemWithThreeSenders(id idOverride: String? = nil) -> ItemDetailState {
        let itemId = idOverride ?? self.itemId
        func layer(_ id: String, _ label: String) -> ImportedCommentaryLayer {
            ImportedCommentaryLayer(
                id: id, itemId: itemId, packageDigest: "digest-\(id)", packageId: "package-\(id)",
                itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                displayLabel: label, importedAt: Date(timeIntervalSince1970: 0), isEnabled: true
            )
        }
        func margin(_ id: String, _ layerId: String, at ms: Int, _ text: String) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(
                id: id, layerId: layerId, packageScopedId: id, createdAt: Date(timeIntervalSince1970: 0),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms),
                approvedTranscript: text,
                resolution: .init(evidenceClass: .acousticVerified, localMediaTimeMs: ms)
            )
        }
        let own = Interjection(
            id: "mine", itemId: itemId, sessionId: "session", targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 10), roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 65_000),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "MY-OWN-NOTE", status: "active"
        )
        var item = ItemDetailState()
        item.id = itemId
        item.title = "Episode"
        item.interjections = [own]
        item.importedCommentaryLayers = [layer("ana", "Ana"), layer("ben", "Ben")]
        item.importedCommentaryInterjections = [
            "ana": [margin("a1", "ana", at: 60_000, "ANA-SAID-THIS"), margin("a2", "ana", at: 600_000, "ANA-AGAIN")],
            "ben": [margin("b1", "ben", at: 62_000, "BEN-SAID-THIS")],
        ]
        return item
    }
}

private final class RecordingReactionsClient: LocalFoundationModelClient, @unchecked Sendable {
    private let reply: String
    private let state: LocalFoundationModelAvailability
    private let lock = NSLock()
    private var recorded: [String] = []

    init(reply: String, availability: LocalFoundationModelAvailability = .available) {
        self.reply = reply
        self.state = availability
    }

    var prompts: [String] { lock.withLock { recorded } }

    func availability() -> LocalFoundationModelAvailability { state }
    func summarizeInterjections(context: String) async throws -> String { "Summary" }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        LocalListeningMapLabel(title: "Chapter \(chapterNumber)", description: "A chapter.")
    }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String { "A map." }

    func summarizeReactions(prompt: String) async throws -> String {
        lock.withLock { recorded.append(prompt) }
        return reply
    }
}
