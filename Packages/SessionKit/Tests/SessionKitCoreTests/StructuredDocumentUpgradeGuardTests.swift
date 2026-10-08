#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SQLite3
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The guards on moving a v1 PDF to a v2 extraction when the PDF is imported again (C1 M3 step 5, I13 rule 1d):
/// the item moves only when nothing of the listener's can land in the wrong place.
///
/// `SessionKitCoreTests` covers the cases where everything lands, and where a Margin's words change. It never
/// meets the other reasons an item must stay (someone else's Margins on it, prepared audio, a Margin that is not a
/// text range, an item that is playing) nor what a successful move rewrites besides offsets (a Margin's edition
/// hash, a session's chapter). Each test here fails if exactly one of those is lost, and the "stays" tests check the
/// reason `plan` gives as well as the outcome, so a different guard cannot pass for the one under test.
final class StructuredDocumentUpgradeGuardTests: XCTestCase {
    private var fixtures: [PDFReimportFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        super.tearDown()
    }

    private func makeFixture() throws -> PDFReimportFixture {
        let fixture = try PDFReimportFixture()
        fixtures.append(fixture)
        return fixture
    }

    // MARK: What a successful move rewrites

    /// The baseline for the "stays" tests below: the same fixture, with nothing extra, does move.
    func testAV1PDFWithOnlyTextMarginsMovesToV2AndKeepsItsRow() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()

        let reimported = try fixture.reimport()

        XCTAssertEqual(reimported.id, fixture.v1.id, "the same item moves; there is no second Library row")
        XCTAssertEqual(try fixture.store.listItems().count, 1)
        XCTAssertNotNil(try fixture.store.loadStructuredDocument(itemId: fixture.v1.id))
        XCTAssertNotEqual(try fixture.store.loadItem(id: fixture.v1.id).text, fixture.v1.text)
    }

    func testAMovedMarginKeepsItsWordsAndItsEditionHashNamesTheNewText() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        let oldEdition = sha256(try XCTUnwrap(fixture.v1.text))
        let withHash = try fixture.addMargin(id: "ij-with-edition", sessionId: "session-reading", words: "Methods", editionHash: oldEdition)
        let withoutHash = try fixture.addMargin(id: "ij-without-edition", sessionId: "session-reading", words: "morning light", editionHash: nil)

        _ = try fixture.reimport()

        let newText = try XCTUnwrap(try fixture.store.loadItem(id: fixture.v1.id).text)
        XCTAssertNotEqual(sha256(newText), oldEdition, "the fixture's v2 text differs, so the old hash would be wrong")
        let moved = Dictionary(uniqueKeysWithValues: try fixture.store.loadInterjections(sessionId: "session-reading").map { ($0.id, $0) })
        XCTAssertEqual(moved[withHash.id].map { words($0, in: newText) }, "Methods")
        XCTAssertEqual(moved[withoutHash.id].map { words($0, in: newText) }, "morning light")
        XCTAssertEqual(moved[withHash.id]?.sourceExactEditionSHA256, sha256(newText),
                       "its offsets now count in the new text, so a shared packet must name the new edition, not the old one")
        XCTAssertNil(moved[withoutHash.id]?.sourceExactEditionSHA256, "a Margin that had no edition hash does not gain one")
    }

    func testAMovedPositionTakesTheNewMapsChapterAtTheNewOffset() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession(chapterId: "chapter-id-from-the-v1-map")
        var withoutChapter = fixture.readingSession(id: "session-no-chapter", chapterId: nil)
        withoutChapter.position.charOffset = try fixture.offset(of: "Sleep improved")
        try fixture.store.saveSession(withoutChapter)

        _ = try fixture.reimport()

        let newText = try XCTUnwrap(try fixture.store.loadItem(id: fixture.v1.id).text)
        let newMap = try XCTUnwrap(try fixture.store.loadListeningMap(itemId: fixture.v1.id))
        let resultsChapter = try XCTUnwrap(newMap.chapters.first { $0.title == "Results" })
        let moved = try XCTUnwrap(try fixture.store.loadSession(id: "session-reading"))
        XCTAssertEqual(String(Array(newText)[moved.position.charOffset...].prefix(14)), "Sleep improved")
        XCTAssertEqual(moved.position.chapterId, resultsChapter.id, "the chapter id belongs to the new map; the v1 map's id no longer exists")
        XCTAssertNotEqual(moved.position.chapterId, "chapter-id-from-the-v1-map")
        XCTAssertNil(try fixture.store.loadSession(id: "session-no-chapter")?.position.chapterId,
                     "a position that had no chapter does not gain one")
    }

    // MARK: Reasons the item stays on v1

    func testSomeoneElsesMarginsOnTheItemKeepItOnItsOldExtraction() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        let layer = ImportedCommentaryLayer(
            id: "layer-from-a-friend", itemId: fixture.v1.id, packageDigest: "digest-1", packageId: "package-1",
            itemIdentity: SharedItemIdentity(itemType: .pdf, title: "Paper", durationMs: nil),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let theirs = ImportedCommentaryInterjection(
            id: "their-margin", layerId: layer.id, packageScopedId: "m1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Look at the methods."
        )
        _ = try fixture.store.importCommentaryLayer(layer, interjections: [theirs])

        try fixture.assertItStaysOnV1(because: .importedCommentary)
        XCTAssertEqual(try fixture.store.loadImportedCommentaryInterjections(layerId: layer.id).map(\.id), ["their-margin"])
    }

    func testPreparedAudioRenderedFromTheOldTextKeepsItOnItsOldExtraction() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        try fixture.store.savePreparedAudioManifest(PreparedAudioManifest(
            id: "manifest-from-v1-text", itemId: fixture.v1.id, sourcePackageId: "source",
            signature: TTSRenderSignature(
                engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "digest"
            ),
            state: .preparing, plannedChunkCount: 3
        ))

        try fixture.assertItStaysOnV1(because: .preparedAudio)
        XCTAssertEqual(try fixture.store.loadPreparedAudioManifests(itemId: fixture.v1.id).map(\.id), ["manifest-from-v1-text"])
    }

    /// A Margin on a summary or reply (`.turn`), a media time or a transcript span has offsets that count in some
    /// other text. Here they are chosen to fall on real words of the PDF ("Methods"), so only the guard stops them
    /// being rewritten as if they were PDF offsets.
    func testAMarginThatIsNotATextRangeKeepsTheItemOnItsOldExtraction() throws {
        for anchorType in [AnchorType.turn, .media, .transcript] {
            let fixture = try makeFixture()
            try fixture.addReadingSession()
            var margin = try fixture.addMargin(id: "ij-\(anchorType.rawValue)", sessionId: "session-reading", words: "Methods", editionHash: nil)
            margin.anchor.anchorType = anchorType
            try fixture.store.saveInterjection(margin)

            try fixture.assertItStaysOnV1(because: .nonTextAnchor(marginIds: [margin.id]), "\(anchorType)")
        }
    }

    func testAnItemThatIsPlayingIsNotUpgradedUnderThePlayer() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        // The engine is the app's playback owner; its current session is the item the listener is hearing now.
        let playing = try fixture.engine.startSession(itemId: fixture.v1.id)
        XCTAssertEqual(playing.itemId, fixture.v1.id, "fixture check: the item is the one playing")
        let before = try fixture.stored()

        let reimported = try fixture.reimport()

        XCTAssertNotEqual(reimported.id, fixture.v1.id, "the new text becomes its own edition")
        XCTAssertEqual(try fixture.store.listItems().count, 2)
        XCTAssertEqual(try fixture.stored(), before, "the playing item's text, Margins and positions are exactly as they were")
    }

    // MARK: The move is written all at once

    func testAMoveThatFailsPartWayLeavesTheItemMarginsAndPositionsAsTheyWere() throws {
        let fixture = try makeFixture()
        try fixture.addReadingSession()
        let upgrade: StructuredDocumentUpgrade
        switch try fixture.plan() {
        case .success(let planned): upgrade = planned
        case .failure(let reason): return XCTFail("fixture check: the item should be upgradable, stays because \(reason)")
        }
        let before = try fixture.stored()
        // The document is written last. Refusing it makes the failure come after the item, map, Margins and
        // sessions have been written, the way a full disk or a locked database could.
        try fixture.execute("""
        CREATE TRIGGER refuse_structured_document BEFORE INSERT ON records
        WHEN NEW.kind = 'structured_document'
        BEGIN SELECT RAISE(ABORT, 'refused for the test'); END;
        """)

        XCTAssertThrowsError(try fixture.store.applyStructuredDocumentUpgrade(upgrade))

        XCTAssertEqual(try fixture.stored(), before,
                       "half a move would leave the new text under Margins whose offsets count in the old text")
        XCTAssertNil(try fixture.store.loadStructuredDocument(itemId: fixture.v1.id))
    }

    // MARK: Helpers

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func words(_ margin: Interjection, in text: String) -> String? {
        let characters = Array(text)
        guard margin.anchor.endChar <= characters.count else { return nil }
        return String(characters[margin.anchor.startChar..<margin.anchor.endChar])
    }
}

/// A PDF imported under the old extraction (v1) in a real SQLite file, and the v2 document it is imported again with.
private final class PDFReimportFixture {
    let path: String
    let store: SQLiteSessionStore
    let engine: SessionEngine
    let v1: Item
    let document: StructuredDocument
    private let url = "shared-file://share-sheet/Paper.pdf"

    init() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-upgrade-guards-\(UUID().uuidString).sqlite").path
        store = try SQLiteSessionStore(path: path)
        engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "pdf", displayName: "PDF", capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
            ]),
            repository: store
        )
        v1 = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: "# Paper\n\n## Methods\n\nWe measured sleep in adults.\nThe effect held across cohorts.\n\n## Results\n\nSleep improved with morning light.",
            contentFormat: .markdown
        ))
        // v2 adds a running head and a reference list around the same sentences, so every Margin below can land.
        document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Paper", role: .title, pageIndex: 0),
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "The effect held across cohorts.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "Results", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "Sleep improved with morning light.", role: .body, pageIndex: 1),
            StructuredDocumentLine(text: "References", role: .reference, pageIndex: 1),
            StructuredDocumentLine(text: "[1] A. Author. Title. 2020.", role: .reference, pageIndex: 1),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 2)
    }

    func remove() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func offset(of words: String) throws -> Int {
        let text = try XCTUnwrap(v1.text)
        return text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: words)).lowerBound)
    }

    func readingSession(id: String, chapterId: String?) -> Session {
        Session(
            id: id, itemId: v1.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: v1.id,
            position: Position(charOffset: 0, chapterId: chapterId), completionPercent: 40, playbackRate: 1
        )
    }

    /// A session paused at "Sleep improved", with Margins on "Methods" and "morning light".
    @discardableResult
    func addReadingSession(chapterId: String? = nil) throws -> Session {
        var session = readingSession(id: "session-reading", chapterId: chapterId)
        session.position.charOffset = try offset(of: "Sleep improved")
        try store.saveSession(session)
        try addMargin(id: "ij-001", sessionId: session.id, words: "Methods", editionHash: nil)
        try addMargin(id: "ij-002", sessionId: session.id, words: "morning light", editionHash: nil)
        return session
    }

    @discardableResult
    func addMargin(id: String, sessionId: String, words: String, editionHash: String?) throws -> Interjection {
        let start = try offset(of: words)
        let margin = Interjection(
            id: id, itemId: v1.id, sessionId: sessionId, targetType: .item, targetId: v1.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: start, endChar: start + words.count, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "Margin \(id)", status: "active", sourceExactEditionSHA256: editionHash
        )
        try store.saveInterjection(margin)
        return margin
    }

    func plan() throws -> Result<StructuredDocumentUpgrade, StructuredDocumentUpgrader.StaysBecause> {
        try StructuredDocumentUpgrader.plan(
            existing: try store.loadItem(id: v1.id),
            document: document,
            listeningMap: StructuredDocumentImport.listeningMap(for: document, title: v1.title, itemId: v1.id),
            repository: store
        )
    }

    func reimport() throws -> Item {
        try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(url: url, title: "Paper"),
            text: document.text,
            contentFormat: .plainText
        ), structuredDocument: document)
    }

    /// Everything the upgrade could touch, as the store holds it now.
    struct Stored: Equatable {
        var item: Item
        var map: ListeningMap?
        var document: StructuredDocument?
        var sessions: [Session]
        var margins: [Interjection]
    }

    func stored() throws -> Stored {
        let sessions = try store.loadSessions(itemId: v1.id).sorted { $0.id < $1.id }
        return Stored(
            item: try store.loadItem(id: v1.id),
            map: try store.loadListeningMap(itemId: v1.id),
            document: try store.loadStructuredDocument(itemId: v1.id),
            sessions: sessions,
            margins: try sessions.flatMap { try store.loadInterjections(sessionId: $0.id) }.sorted { $0.id < $1.id }
        )
    }

    /// `plan` refuses for exactly `reason`, and importing the PDF again leaves the v1 item as it was and adds a second row.
    func assertItStaysOnV1(
        because reason: StructuredDocumentUpgrader.StaysBecause, _ context: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let before = try stored()
        switch try plan() {
        case .success: XCTFail("plan should keep the item on v1 because of \(reason). \(context)", file: file, line: line)
        case .failure(let actual): XCTAssertEqual(actual, reason, context, file: file, line: line)
        }

        let reimported = try reimport()

        XCTAssertNotEqual(reimported.id, v1.id, "the new text becomes its own edition. \(context)", file: file, line: line)
        XCTAssertEqual(try store.listItems().count, 2, context, file: file, line: line)
        XCTAssertEqual(try stored(), before, "the v1 text, Margins and positions are exactly as they were. \(context)", file: file, line: line)
        XCTAssertNil(try store.loadStructuredDocument(itemId: v1.id), context, file: file, line: line)
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw NSError(domain: "PDFReimportFixture", code: 1) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "PDFReimportFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }
}
