import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3777: the plan kind (plain, or with note chunks) is decided once where a preparation is created, and every later
/// step takes it from the manifest or the identity. These pin the rule, the identity helpers and the spoken text the
/// player and the assembly build for the notes plan.
final class FootnotePlanKindTests: XCTestCase {
    private typealias Planner = NarrationChunkPlanner

    private let tides = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    """
    private let plainProse = "Plain prose. Another sentence of it. And a third one to be sure."

    private func manifest(
        identity: String?, state: PreparedAudioState = .readyOffline, chunks: Bool = true, artifact: Bool = false,
        id: String = "prepared-a"
    ) -> PreparedAudioManifest {
        var manifest = PreparedAudioManifest(
            id: id, itemId: "a", sourcePackageId: "source",
            signature: .init(engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                             synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: id),
            state: state, plannedChunkCount: 3, articleIdentity: identity)
        if chunks {
            manifest.chunks = [PreparedAudioChunk(
                id: "c0", index: 0, sourceRange: SourceLocator(documentId: "d", segmentId: "chunk-0", utf8Start: 0, utf8End: 4),
                relativePath: "a.wav", byteCount: 1, checksumSHA256: "x", durationMs: 1)]
        }
        if artifact {
            manifest.artifact = PreparedAudioArtifact(relativePath: "a.m4a", byteCount: 1, checksumSHA256: "x", durationMs: 1)
        }
        return manifest
    }

    // MARK: Identities

    func testAnIdentityNamesOneOfTheTwoPlans() {
        let plain = Planner.identity(ofArticle: tides)
        let inline = Planner.identity(ofArticle: tides, asides: true)
        XCTAssertTrue(Planner.isIdentity(plain, ofArticle: tides))
        XCTAssertTrue(Planner.isIdentity(inline, ofArticle: tides))
        XCTAssertFalse(Planner.isIdentity("something else", ofArticle: tides))
        XCTAssertFalse(Planner.isIdentity(plain, ofArticle: tides + " edited"), "another text's identity is not this one's")
        XCTAssertFalse(Planner.isIdentity(inline, ofArticle: tides + " edited"))
    }

    func testOnlyTheNotesIdentityUsesAsides() {
        let plain = Planner.identity(ofArticle: tides)
        let inline = Planner.identity(ofArticle: tides, asides: true)
        XCTAssertFalse(Planner.usesAsides(identity: plain, ofArticle: tides))
        XCTAssertTrue(Planner.usesAsides(identity: inline, ofArticle: tides))
        XCTAssertFalse(Planner.usesAsides(identity: nil, ofArticle: tides), "a manifest from before #312 is plain")
        XCTAssertFalse(Planner.usesAsides(identity: "unrelated", ofArticle: tides))
        XCTAssertFalse(Planner.usesAsides(identity: inline, ofArticle: tides + " edited"))
    }

    func testOneCallAnswersWhetherAnIdentityIsThisTextsAndWhichPlanItNames() {
        let plain = Planner.identity(ofArticle: tides)
        let inline = Planner.identity(ofArticle: tides, asides: true)
        XCTAssertEqual(Planner.planUsesAsides(identity: plain, ofArticle: tides), false)
        XCTAssertEqual(Planner.planUsesAsides(identity: inline, ofArticle: tides), true)
        XCTAssertNil(Planner.planUsesAsides(identity: "unrelated", ofArticle: tides))
        XCTAssertNil(Planner.planUsesAsides(identity: inline, ofArticle: tides + " edited"))
        XCTAssertEqual(Planner.planUsesAsides(identity: Planner.identity(ofArticle: plainProse), ofArticle: plainProse), false)
        XCTAssertNil(Planner.planUsesAsides(identity: inline, ofArticle: plainProse), "no note, so no second plan to name")
    }

    func testAnArticleWithoutANoteHasOneIdentityAndNoAsides() {
        let identity = Planner.identity(ofArticle: plainProse)
        XCTAssertEqual(Planner.identity(ofArticle: plainProse, asides: true), identity)
        XCTAssertFalse(Planner.usesAsides(identity: identity, ofArticle: plainProse))
        XCTAssertTrue(Planner.isIdentity(identity, ofArticle: plainProse))
        XCTAssertFalse(Planner.hasFootnotesToReadWhereCited(in: plainProse))
        XCTAssertTrue(Planner.hasFootnotesToReadWhereCited(in: tides))
    }

    /// Per-chunk callers ask about one text over and over, then a listener opens another article.
    func testTheMemoFollowsTheTextItWasLastAskedAbout() {
        let other = "Another claim.[^a] More words follow it.\n\n[^a]: A different note."
        for text in [tides, other, plainProse, tides, other] {
            XCTAssertEqual(Planner.matchedFootnotes(in: text), FootnoteAnchors.find(in: text), text)
        }
    }

    // MARK: The spoken text the player holds

    func testASilencedProjectionOfAPrefaceAndArticleMatchesTheNotesPlan() throws {
        let preface = "Overview. A short summary of the piece. "
        let spokenSource = preface + tides
        let projection = try XCTUnwrap(Planner.silencedSpeech(source: spokenSource, endingWith: tides))
        let body = projection.text.components(separatedBy: "Then they leave").first ?? ""
        XCTAssertFalse(body.contains("footnote 1") || body.contains("footnote 2"),
                       "the citations are silent (the definitions below still say their label)")
        XCTAssertTrue(SpeechTextNormalizer.normalize(spokenSource).contains("day. footnote 1"), "today the marker is spoken")
        let article = Planner.articlePlan(tides, asides: true)
        XCTAssertTrue(projection.text.hasSuffix(article.normalizedText),
                      "the article's tail of the held text is the plan's own text, or the plan matches nothing")
        let start = projection.spokenCharacterOffset(atOrAfterSourceOffset: preface.count)
        let plan = Planner.spokenPlan(spokenText: projection.text, articleText: tides, articleSpokenStart: start, asides: true)
        XCTAssertEqual(plan.articleIdentity, Planner.identity(ofArticle: tides, asides: true))
        XCTAssertTrue(plan.chunks.contains { if case .aside = $0.footnote { true } else { false } })
        XCTAssertTrue(plan.chunks.prefix(while: { $0.articleIndex == nil }).count > 0, "the preface is still its own chunks")
    }

    func testASilencedProjectionOfTheArticleAloneMatchesToo() throws {
        let projection = try XCTUnwrap(Planner.silencedSpeech(source: tides, endingWith: tides))
        let plan = Planner.spokenPlan(spokenText: projection.text, articleText: tides, articleSpokenStart: 0, asides: true)
        XCTAssertEqual(plan.articleIdentity, Planner.identity(ofArticle: tides, asides: true))
    }

    func testThereIsNoSilencedProjectionWhenThePlainOneIsRight() {
        XCTAssertNil(Planner.silencedSpeech(source: plainProse, endingWith: plainProse), "no matched note")
        XCTAssertNil(Planner.silencedSpeech(source: "Overview. " + plainProse, endingWith: tides), "not this article's text")
        XCTAssertNil(Planner.silencedSpeech(source: tides, endingWith: ""))
        XCTAssertNil(Planner.silencedSpeech(source: "Intro. " + tides + " trailing", endingWith: tides), "the article must end the text")
    }

    func testAssemblyUsesTheNotesPlansOwnOffsets() throws {
        let item = Item(id: "a", title: "T", mediaType: "article", text: tides, externalReference: nil, status: "ready")
        let speech = try XCTUnwrap(PreparedSpeechText(item: item, document: nil))
        XCTAssertEqual(speech.assemblyProjection().text, Planner.articlePlan(tides).normalizedText)
        XCTAssertEqual(speech.assemblyProjection(asides: true).text, Planner.articlePlan(tides, asides: true).normalizedText,
                       "the chunks' spoken offsets are in the notes plan's text, so the projection is too")
        let prose = try XCTUnwrap(PreparedSpeechText(item: Item(id: "b", title: "T", mediaType: "article", text: plainProse, externalReference: nil, status: "ready"), document: nil))
        XCTAssertEqual(prose.assemblyProjection(asides: true), prose.assemblyProjection())
    }

    func testNoTimelineSegmentOfTheNotesPlanHasAnInvertedCharacterRange() throws {
        // An aside has no source characters, and its citation can follow the full stop of the sentence it ends. The
        // segment's range then ran from after the marker back to before it, and a Margin made during the note
        // exported that range, which a packet's validator rejects (Build 29 too).
        let item = Item(id: "a", title: "T", mediaType: "article", text: tides, externalReference: nil, status: "ready")
        let projection = try XCTUnwrap(PreparedSpeechText(item: item, document: nil)).assemblyProjection(asides: true)
        let plan = Planner.articlePlan(tides, asides: true)
        XCTAssertTrue(plan.chunks.contains { $0.sourceLength == 0 }, "the fixture has asides")
        var ms = 0
        for chunk in plan.chunks {
            let pieces = NarrationTimelinePieces.pieces(
                spokenRange: chunk.startOffset..<(chunk.startOffset + chunk.sourceLength),
                startMs: ms, endMs: ms + 1_000, projection: projection, source: Array(tides))
            ms += 1_000
            for piece in pieces {
                XCTAssertGreaterThanOrEqual(piece.endChar, piece.startChar, "chunk \(chunk.index) \(chunk.footnote.map(String.init(describing:)) ?? "body")")
            }
        }
    }

    // MARK: The notes chapter skips what was heard

    /// Plays `tags` front to back the way the player steps, recording each aside that ends, and returns the indexes played.
    private func playThrough(_ tags: [Planner.FootnoteTag?], heard: inout FootnoteHeardSet, hearing labels: Set<String>) -> [Int] {
        var played: [Int] = []
        var index: Int? = 0
        while let current = index {
            played.append(current)
            if case .aside(let label)? = tags[current], labels.contains(label) {
                heard.recordPlayedToEnd(chunkAt: current, tags: tags, itemId: "a")
            }
            index = heard.firstPlayableIndex(from: current + 1, tags: tags, itemId: "a")
        }
        return played
    }

    func testTheNotesChapterSkipsEveryNoteHeardWhereItWasCited() {
        let tags = Planner.articlePlan(tides, asides: true).chunks.map(\.footnote)
        XCTAssertTrue(tags.contains { if case .definition? = $0 { true } else { false } })
        var heard = FootnoteHeardSet()
        let played = playThrough(tags, heard: &heard, hearing: ["1", "2"])
        XCTAssertEqual(played, tags.indices.filter { if case .definition? = tags[$0] { false } else { true } },
                       "every body chunk and every aside, no definition")
    }

    func testANoteThatWasNotHeardIsStillReadInTheNotesChapter() {
        let tags = Planner.articlePlan(tides, asides: true).chunks.map(\.footnote)
        var heard = FootnoteHeardSet()
        let played = playThrough(tags, heard: &heard, hearing: ["1"])
        let playedDefinitions = played.compactMap { index -> String? in
            if case .definition(let label)? = tags[index] { return label }
            return nil
        }
        XCTAssertFalse(playedDefinitions.isEmpty)
        XCTAssertTrue(playedDefinitions.allSatisfy { $0 == "2" }, "note 1 was heard, note 2 was not")
        var nothing = FootnoteHeardSet()
        XCTAssertEqual(playThrough(tags, heard: &nothing, hearing: []), Array(tags.indices), "a listener who heard no tone hears every note")
    }

    func testThereIsNothingPlayableAfterTheLastChunk() {
        let heard = FootnoteHeardSet()
        let tags: [Planner.FootnoteTag?] = [nil, .aside("1"), nil, .definition("1")]
        XCTAssertEqual(heard.firstPlayableIndex(from: 3, tags: tags, itemId: "a"), 3, "a note not heard plays")
        XCTAssertNil(heard.firstPlayableIndex(from: 4, tags: tags, itemId: "a"))
        XCTAssertNil(heard.firstPlayableIndex(from: 99, tags: tags, itemId: "a"))
        XCTAssertEqual(heard.firstPlayableIndex(from: -3, tags: tags, itemId: "a"), 0)
        var heardOne = FootnoteHeardSet()
        heardOne.recordPlayedToEnd(chunkAt: 1, tags: tags, itemId: "a")
        XCTAssertNil(heardOne.firstPlayableIndex(from: 3, tags: tags, itemId: "a"), "the heard note's definition was the last chunk")
        XCTAssertEqual(heardOne.firstPlayableIndex(from: 3, tags: tags, itemId: "another item"), 3, "heard notes belong to their item")
    }

    // MARK: The decision where a preparation is created

    private func decide(
        _ mode: FootnoteMode = .whereCited, pdf: Bool = false, text: String? = nil, _ manifests: [PreparedAudioManifest] = []
    ) -> Bool {
        FootnotePlanDecision.asides(mode: mode, isPDF: pdf, articleText: text ?? tides, manifests: manifests)
    }

    func testANewArticleIsReadWhereCitedByDefault() {
        XCTAssertTrue(decide())
        XCTAssertTrue(decide(.chime))
        XCTAssertFalse(decide(.atEnd))
    }

    func testPDFsAndArticlesWithoutANoteAreNeverPlannedWithAsides() {
        XCTAssertFalse(decide(pdf: true))
        XCTAssertFalse(decide(text: plainProse))
        XCTAssertFalse(decide(text: "A claim.[^1] No definition.", []))
    }

    func testAudioPreparedWithTheNotesAtTheEndKeepsItsPlan() {
        let plain = Planner.identity(ofArticle: tides)
        for held in [
            manifest(identity: plain),
            manifest(identity: plain, state: .preparing),
            manifest(identity: plain, state: .pausedForThermal),
            manifest(identity: plain, state: .stopped),
            manifest(identity: plain, state: .needsRepreparation), // retired, but its intact chunks are resumed
            manifest(identity: plain, chunks: false, artifact: true),
            manifest(identity: nil), // before #312 every plan was plain
        ] {
            XCTAssertFalse(decide(.whereCited, [held]), "\(held.state) chunks=\(held.chunks.count) identity=\(held.articleIdentity ?? "nil")")
            XCTAssertFalse(decide(.chime, [held]))
        }
    }

    func testPlainPreparationsThatHoldNothingLetThePlanChange() {
        let plain = Planner.identity(ofArticle: tides)
        for empty in [
            manifest(identity: plain, state: .needsRepreparation, chunks: false),
            manifest(identity: plain, state: .failed),
            manifest(identity: plain, state: .notPrepared),
            manifest(identity: plain, state: .preparing, chunks: false), // begun, nothing rendered
            manifest(identity: Planner.identity(ofArticle: "an older text of the article")), // another text's audio
        ] {
            XCTAssertTrue(decide(.whereCited, [empty]), "\(empty.state) chunks=\(empty.chunks.count)")
        }
    }

    func testAPreparationWithNotesDoesNotHoldThePlanPlain() {
        let inline = Planner.identity(ofArticle: tides, asides: true)
        XCTAssertTrue(decide(.whereCited, [manifest(identity: inline)]), "it is already the notes plan: nothing to protect")
        XCTAssertFalse(decide(.atEnd, [manifest(identity: inline)]), "the listener chose the notes at the end")
    }

    func testChoosingTheNotesAtTheEndPlansPlainEvenWhereANotesPlanIsReady() {
        // A Default taken (#3777): the picker is the listener's own choice, so it wins over audio already made with
        // note chunks, and the item is prepared again plain. The reverse never happens: plain audio holds the plan.
        let inline = Planner.identity(ofArticle: tides, asides: true)
        XCTAssertFalse(decide(.atEnd, [manifest(identity: inline, state: .readyOffline, artifact: true)]))
        XCTAssertTrue(decide(.whereCited, [manifest(identity: inline, state: .readyOffline, artifact: true)]))
    }

    func testAnyVoicesPlainAudioHoldsThePlan() {
        let plain = Planner.identity(ofArticle: tides)
        let other = manifest(identity: plain, id: "prepared-a-other-voice")
        let retired = manifest(identity: plain, state: .needsRepreparation, chunks: false, id: "prepared-a-mine")
        XCTAssertFalse(decide(.whereCited, [retired, other]),
                       "the rule reads the item's preparations, not one voice's, so every caller reaches the same answer")
    }

    // MARK: A manifest of either plan is still the item's

    func testAManifestOfEitherPlanStaysCurrentForItsItem() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "plan-kind-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SQLiteSessionStore(path: path.path)
        let engine = SessionEngine(profile: .init(id: "p", displayName: "P", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let item = try engine.importBrowserTextInBackground(.init(
            captureMode: .markdownFile, source: .init(url: "shared-file://share-sheet/Notes.md", title: "Notes"),
            text: tides, contentFormat: .plainText))
        let text = try XCTUnwrap(item.text)
        try XCTSkipUnless(Planner.hasFootnotesToReadWhereCited(in: text), "the import changed the notes' shape")
        var saved = manifest(identity: Planner.identity(ofArticle: text, asides: true))
        saved.itemId = item.id
        try store.savePreparedAudioManifest(saved)
        XCTAssertTrue(PreparedAudioEnqueue.isStillCurrent(saved, itemText: item.text, sourceText: text, repository: store),
                      "a preparation of the notes plan must not read as stale, or no chunk of it could be saved")
        var plain = saved
        plain.articleIdentity = Planner.identity(ofArticle: text)
        try store.savePreparedAudioManifest(plain)
        XCTAssertTrue(PreparedAudioEnqueue.isStillCurrent(plain, itemText: item.text, sourceText: text, repository: store))
        var stale = plain
        stale.articleIdentity = Planner.identity(ofArticle: "an older text")
        try store.savePreparedAudioManifest(stale)
        XCTAssertFalse(PreparedAudioEnqueue.isStillCurrent(stale, itemText: item.text, sourceText: text, repository: store))
    }
}
