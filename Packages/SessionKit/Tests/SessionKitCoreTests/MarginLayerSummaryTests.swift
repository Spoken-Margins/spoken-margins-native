import Foundation
import XCTest
@testable import SessionKit

/// #476: the prompt, the reply parser and the on-device record behind "Where people reacted".
final class MarginLayerSummaryTests: XCTestCase {
    fileprivate let itemId = "episode-1"
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    // MARK: Layer picker

    func testUncheckingALayerRemovesItsMarginsFromTheListAndFromThePrompt() {
        let layers = [layer("ana", "Ana"), layer("ben", "Ben"), layer("cy", "Cy")]
        let margins = [
            shared("a1", layer: "ana", at: 60_000, "ANA-SAID-THIS"),
            shared("b1", layer: "ben", at: 70_000, "BEN-SAID-THIS"),
            shared("c1", layer: "cy", at: 80_000, "CY-SAID-THIS"),
        ]
        func input(_ chosen: Set<String>) -> MarginLayerSynthesis.Input {
            MarginLayerSynthesis.input(itemId: itemId, layers: layers, interjections: margins, chosenLayerIds: chosen)
        }
        let all = input(["ana", "ben", "cy"])
        XCTAssertEqual(MarginLayerSynthesis.hotSpots(all).flatMap(\.entries).count, 3)
        let allPrompt = MarginLayerSynthesis.prompt(for: all)
        for text in ["ANA-SAID-THIS", "BEN-SAID-THIS", "CY-SAID-THIS"] { XCTAssertTrue(allPrompt.contains(text)) }

        let withoutBen = input(["ana", "cy"])
        let entries = MarginLayerSynthesis.hotSpots(withoutBen).flatMap(\.entries)
        XCTAssertEqual(entries.map(\.senderLabel), ["Ana", "Cy"])
        let prompt = MarginLayerSynthesis.prompt(for: withoutBen)
        XCTAssertFalse(prompt.contains("BEN-SAID-THIS"))
        XCTAssertFalse(prompt.contains("Ben"))
        XCTAssertTrue(prompt.contains("ANA-SAID-THIS") && prompt.contains("CY-SAID-THIS"))
    }

    // MARK: Prompt

    func testPromptListsPlacedMarginsInSourceOrderWithTheirIdsAndLeavesOutNotPlaced() {
        let margins = [
            shared("late", layer: "ben", at: 3_700_000, "Much later"),
            shared("early", layer: "ana", at: 760_000, "Line one\nline two"),
            shared("lost", layer: "ana", at: 1_000, "NOT-PLACED-TEXT", resolution: .init(evidenceClass: .unresolved)),
        ]
        let input = MarginLayerSynthesis.input(
            itemId: itemId, layers: [layer("ana", "Ana"), layer("ben", "Ben")], interjections: margins, chosenLayerIds: ["ana", "ben"]
        )
        let prompt = MarginLayerSynthesis.prompt(for: input)
        XCTAssertTrue(prompt.contains("[m1] Ana at 12:40: Line one line two\n[m2] Ben at 1:01:40: Much later"), prompt)
        XCTAssertFalse(prompt.contains("NOT-PLACED-TEXT"))
    }

    func testPromptStaysWithinItsCaps() {
        let long = String(repeating: "word ", count: 400)
        let margins = (0..<80).map { shared("m\($0)", layer: "ana", at: $0 * 60_000, long) }
        let input = MarginLayerSynthesis.input(itemId: itemId, layers: [layer("ana", "Ana")], interjections: margins, chosenLayerIds: ["ana"])
        let prompt = MarginLayerSynthesis.prompt(for: input)
        let lines = prompt.split(separator: "\n").filter { $0.hasPrefix("[m") }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertLessThan(lines.count, 80)
        XCTAssertTrue(lines.allSatisfy { $0.count <= MarginLayerSynthesis.promptEntryCharacterLimit + 30 })
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.count }, MarginLayerSynthesis.promptCharacterLimit)
    }

    // MARK: Reading the reply

    func testParseClaimsTable() {
        let cases: [(String, [MarginLayerSynthesis.ModelClaim])] = [
            ("Ana and Ben disagreed. [m1][m2]", [.init(text: "Ana and Ben disagreed.", citationIds: ["m1", "m2"])]),
            ("Ana and Ben disagreed. [m1, m2]", [.init(text: "Ana and Ben disagreed.", citationIds: ["m1", "m2"])]),
            ("[m1] Ana laughed.", [.init(text: "Ana laughed.", citationIds: ["m1"])]),
            ("- Ana laughed. [m1]", [.init(text: "Ana laughed.", citationIds: ["m1"])]),
            ("• Ana laughed [M1]", [.init(text: "Ana laughed", citationIds: ["m1"])]),
            ("Ana laughed. [m1][m1]", [.init(text: "Ana laughed.", citationIds: ["m1"])]),
            ("Nobody cited this.", [.init(text: "Nobody cited this.", citationIds: [])]),
            ("Ana said [sic] it. [m3]", [.init(text: "Ana said [sic] it.", citationIds: ["m3"])]),
            ("Ana said [m] and [mx1] and [m1x]. [m4]", [.init(text: "Ana said [m] and [mx1] and [m1x].", citationIds: ["m4"])]),
            ("Unclosed [m1 bracket", [.init(text: "Unclosed [m1 bracket", citationIds: [])]),
            ("[m1][m2]", []),
            ("", []),
            ("   \n\n  ", []),
            ("  Spaced   out   words [m2]  ", [.init(text: "Spaced out words", citationIds: ["m2"])]),
            ("First. [m1]\nSecond. [m2]\r\nThird.", [
                .init(text: "First.", citationIds: ["m1"]),
                .init(text: "Second.", citationIds: ["m2"]),
                .init(text: "Third.", citationIds: []),
            ]),
        ]
        for (reply, expected) in cases {
            XCTAssertEqual(MarginLayerSynthesis.parseClaims(reply), expected, "reply: \(reply.debugDescription)")
        }
    }

    func testReplyThroughTheValidatorKeepsOnlyClaimsThatCiteRealMargins() throws {
        let input = MarginLayerSynthesis.input(
            itemId: itemId, layers: [layer("ana", "Ana")],
            interjections: [shared("a1", layer: "ana", at: 5_000, "Funny")], chosenLayerIds: ["ana"]
        )
        let reply = "Ana found it funny. [m1]\nCy agreed. [m1][m7]\nEveryone clapped."
        let checked = try MarginLayerSynthesis.check(
            MarginLayerSynthesis.parseClaims(reply), against: input, modelId: "m", promptVersion: MarginLayerSynthesis.promptVersion
        )
        let stored = StoredReactionSummary(itemId: itemId, generatedAt: Date(timeIntervalSince1970: 100), input: input, checked: checked)
        XCTAssertEqual(stored.claims.map(\.text), ["Ana found it funny."])
        XCTAssertEqual(stored.citations.map(\.marginId), ["a1"])
        XCTAssertEqual(stored.provenance.promptVersion, "reactions.v1")
    }

    // MARK: Keeping it on the phone

    func testStoreRoundTripsReplacesOnTheNextRunAndKeepsItemsApart() throws {
        let store = ReactionSummaryStore(directory: try temporaryDirectory().appendingPathComponent("ReactionSummaries"))
        XCTAssertNil(store.load(itemId: itemId))
        let first = try summary(itemId: itemId, claim: "FIRST-RUN", at: 100)
        try store.save(first)
        XCTAssertEqual(store.load(itemId: itemId), first)

        let second = try summary(itemId: itemId, claim: "SECOND-RUN", at: 200)
        try store.save(second)
        XCTAssertEqual(store.load(itemId: itemId), second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 1, "replaced, not appended")

        try store.save(try summary(itemId: "episode/2 ../x", claim: "OTHER", at: 300))
        XCTAssertEqual(store.load(itemId: itemId)?.claims.first?.text, "SECOND-RUN")
        XCTAssertEqual(store.load(itemId: "episode/2 ../x")?.claims.first?.text, "OTHER")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 2)

        store.delete(itemId: itemId)
        XCTAssertNil(store.load(itemId: itemId))
    }

    func testASummaryWhoseMarginsAreGoneIsOrphanedAndAllListsEverySummary() throws {
        let store = ReactionSummaryStore(directory: try temporaryDirectory())
        XCTAssertEqual(store.all(), [])
        let kept = try summary(itemId: itemId, claim: "KEPT", at: 1)
        try store.save(kept)
        try store.save(try summary(itemId: "episode-2", claim: "OTHER", at: 2))
        XCTAssertEqual(store.all().map(\.itemId).sorted(), [itemId, "episode-2"])
        XCTAssertFalse(kept.isOrphaned(liveMarginIds: ["a1", "b1"]))
        XCTAssertTrue(kept.isOrphaned(liveMarginIds: ["b1"]), "the cited Margin was deleted")
        XCTAssertTrue(kept.isOrphaned(liveMarginIds: []))
    }

    func testAnUnreadableFileIsNoSummary() throws {
        let directory = try temporaryDirectory()
        let store = ReactionSummaryStore(directory: directory)
        try store.save(try summary(itemId: itemId, claim: "KEPT", at: 1))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("{ not json".utf8).write(to: file)
        XCTAssertNil(store.load(itemId: itemId))
    }

    func testASummaryGoesStaleWhenTheChosenMarginsChange() throws {
        let layers = [layer("ana", "Ana"), layer("ben", "Ben")]
        let margins = [shared("a1", layer: "ana", at: 1_000, "One"), shared("b1", layer: "ben", at: 2_000, "Two")]
        let both = MarginLayerSynthesis.input(itemId: itemId, layers: layers, interjections: margins, chosenLayerIds: ["ana", "ben"])
        let checked = try MarginLayerSynthesis.check(
            [.init(text: "Both spoke.", citationIds: ["m1", "m2"])], against: both, modelId: "m", promptVersion: "p"
        )
        let stored = StoredReactionSummary(itemId: itemId, generatedAt: Date(), input: both, checked: checked)
        XCTAssertFalse(stored.isStale(for: both))
        let onlyAna = MarginLayerSynthesis.input(itemId: itemId, layers: layers, interjections: margins, chosenLayerIds: ["ana"])
        XCTAssertTrue(stored.isStale(for: onlyAna))
    }

    func testAStoredSummaryNeverAppearsInAnExport() throws {
        let item = Item(id: itemId, title: "Episode", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session", itemId: itemId, status: "in_progress", phase: .itemPlayback,
                              currentTargetType: .itemTextTTS, currentTargetId: itemId,
                              position: Position(), completionPercent: 0, playbackRate: 1)
        let note = Interjection(
            id: "note", itemId: itemId, sessionId: session.id, targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
            transcript: "My own note", cleanedTranscript: nil, displayText: nil, status: "active"
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "summary-export", displayName: "Summary export", capabilities: ["sync": ["canonical_persistence"]]),
            repository: InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [note.id: note])
        )
        let store = ReactionSummaryStore(directory: try temporaryDirectory())
        try store.save(try summary(itemId: itemId, claim: "GENERATED-CLAIM-TEXT", at: 1))

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id, includeFullText: true, includeReference: true,
            includeListeningMap: true, includeInterjections: true
        ))
        let json = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        let markdown = SessionExportMarkdownRenderer.render(export)
        XCTAssertTrue(json.contains("My own note") && markdown.contains("My own note"))
        for text in [json, markdown] {
            XCTAssertFalse(text.contains("GENERATED-CLAIM-TEXT"))
            XCTAssertFalse(text.contains("reactions.v1"))
        }
    }

    // MARK: Fixtures

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reaction-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func summary(itemId: String, claim: String, at time: TimeInterval) throws -> StoredReactionSummary {
        let input = MarginLayerSynthesis.input(
            itemId: itemId, layers: [layer("ana", "Ana", itemId: itemId)],
            interjections: [shared("a1", layer: "ana", at: 5_000, "Funny")], chosenLayerIds: ["ana"]
        )
        let checked = try MarginLayerSynthesis.check(
            [.init(text: claim, citationIds: ["m1"])], against: input, modelId: "model", promptVersion: MarginLayerSynthesis.promptVersion
        )
        return StoredReactionSummary(itemId: itemId, generatedAt: Date(timeIntervalSince1970: time), input: input, checked: checked)
    }

    fileprivate func layer(_ id: String, _ label: String, itemId: String? = nil) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: itemId ?? self.itemId, packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            displayLabel: label, importedAt: Date(timeIntervalSince1970: 0), isEnabled: true
        )
    }

    fileprivate func shared(
        _ id: String, layer: String, at ms: Int, _ text: String, resolution: ImportedAnchorResolution? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: id, createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms),
            approvedTranscript: text,
            resolution: resolution ?? .init(evidenceClass: .acousticVerified, localMediaTimeMs: ms)
        )
    }
}

// MARK: Offering the screen

extension MarginLayerSummaryTests {
    func testTheScreenIsOfferedFromTwoSenders() {
        let layers = [layer("ana", "Ana"), layer("ben", "Ben"), layer("cy", "Cy")]
        let margins = ["ana": [shared("a1", layer: "ana", at: 1_000, "One")], "ben": [shared("b1", layer: "ben", at: 2_000, "Two")]]
        func offered(_ layers: [ImportedCommentaryLayer], _ margins: [String: [ImportedCommentaryInterjection]], own: [Interjection] = []) -> Bool {
            MarginLayerSynthesis.offersReactions(itemId: "episode-1", layers: layers, interjections: margins, ownMargins: own)
        }
        XCTAssertTrue(offered(layers, margins))
        XCTAssertFalse(offered([layers[0]], margins), "one sender")
        XCTAssertFalse(offered([layers[0], layers[2]], margins), "a layer with no Margins is not a sender")
        XCTAssertTrue(offered([layers[0]], margins, own: [ownMargin("mine")]), "one friend and you")
        XCTAssertFalse(offered([], [:], own: [ownMargin("mine"), ownMargin("mine-2")]), "only you, however many Margins")
        XCTAssertFalse(offered([layers[0]], margins, own: [ownMargin("gone", status: "deleted")]))
        var disabled = layers[1]
        disabled.isEnabled = false
        XCTAssertFalse(offered([layers[0], disabled], margins), "a disabled layer is not a sender")
    }

    private func ownMargin(_ id: String, status: String = "active") -> Interjection {
        Interjection(
            id: id, itemId: "episode-1", sessionId: "session", targetType: .item, targetId: "episode-1",
            createdAt: Date(timeIntervalSince1970: 10), roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "Mine", status: status
        )
    }
}
