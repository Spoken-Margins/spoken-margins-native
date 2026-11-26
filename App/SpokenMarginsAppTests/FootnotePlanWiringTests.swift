import AVFoundation
import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSupertonic
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #3777: an article with a note that can be read where it is cited has two plans. A preparation is created as one of
/// them and every later step follows it, so prepared audio of one is never matched to the other, and assembly reads each
/// note once.
final class FootnotePlanWiringTests: XCTestCase {
    private let article = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    """

    private struct Fixture { let root: URL; let prepared: URL; let store: SQLiteSessionStore; let item: Item }

    private func makeFixture(mediaType: String = "article") throws -> Fixture {
        let root = try makeRoot()
        return try makeFixture(root: root, store: SQLiteSessionStore(path: root.appending(path: "store.sqlite").path), mediaType: mediaType)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "footnote-plan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFixture(root: URL, store: SQLiteSessionStore, mediaType: String = "article") throws -> Fixture {
        let item = Item(id: "item", title: "Tides", mediaType: mediaType, text: article, externalReference: nil, status: "ready")
        try store.saveItem(item)
        return Fixture(root: root, prepared: root.appending(path: "Prepared", directoryHint: .isDirectory), store: store, item: item)
    }

    private func signature(_ digest: String = "one") -> TTSRenderSignature {
        TTSRenderSignature(engine: "supertonic", modelRevision: "3", assetManifestHash: "assets", voiceStyleHash: digest,
                           synthesisParametersHash: "parameters", normalizationVersion: "normalization", chunkingVersion: "chunking", digest: digest)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: FootnoteMode.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FootnoteMode.storageKey)
        super.tearDown()
    }

    /// Saves one small file for every chunk of `plan`, as a preparation of `asides` kind.
    private func prepare(_ fixture: Fixture, coordinator: PreparedAudioCoordinator, asides: Bool) async throws -> [PreparedChunkPlan] {
        let plan = PreparedChunkPlan.articlePlan(article, asides: asides)
        _ = try await coordinator.begin(itemId: "item", sourceText: article, signature: signature(), plan: plan, asides: asides)
        for entry in plan {
            let input = fixture.root.appending(path: "input-\(asides)-\(entry.index).wav")
            try Data([UInt8(entry.index)]).write(to: input)
            try await coordinator.commit(itemId: "item", signature: signature(), plan: entry, sourceText: article,
                                         audioURL: input, durationMs: 1_000, asides: asides)
        }
        return plan
    }

    func testThePlanWithNotesHasChunksThePlainPlanDoesNot() {
        let plain = PreparedChunkPlan.articlePlan(article)
        let inline = PreparedChunkPlan.articlePlan(article, asides: true)
        XCTAssertNotEqual(plain.count, inline.count)
        XCTAssertTrue(plain.allSatisfy { $0.footnote == nil })
        XCTAssertTrue(inline.contains { if case .aside? = $0.footnote { true } else { false } })
        XCTAssertTrue(inline.contains { if case .definition? = $0.footnote { true } else { false } })
    }

    func testAPreparationOfTheNotesPlanIsSavedAndFoundUnderItsOwnIdentity() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = try await prepare(fixture, coordinator: coordinator, asides: true)
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: PreparedAudioCoordinator.manifestId(itemId: "item", signature: signature())))
        XCTAssertEqual(manifest.articleIdentity, NarrationChunkPlanner.identity(ofArticle: article, asides: true))
        XCTAssertEqual(manifest.chunks.count, plan.count)
        XCTAssertTrue(NarrationChunkPlanner.usesAsides(identity: manifest.articleIdentity, ofArticle: article))
        for entry in plan {
            let found = try await coordinator.committedChunk(itemId: "item", signature: signature(), plan: entry, sourceText: article, asides: true)
            XCTAssertNotNil(found, "chunk \(entry.index) of the notes plan")
            let asPlain = try await coordinator.committedChunk(itemId: "item", signature: signature(), plan: entry, sourceText: article, asides: false)
            XCTAssertNil(asPlain, "the plain plan never reads the notes plan's audio (chunk \(entry.index))")
        }
        XCTAssertTrue(PreparedAudioCoordinator.isPrepared(plan, in: manifest, sourceText: article, asides: true))
        XCTAssertFalse(PreparedAudioCoordinator.isPrepared(plan, in: manifest, sourceText: article, asides: false))
        XCTAssertTrue(PreparedAudioCoordinator.matchingChunks(in: manifest, plan: PreparedChunkPlan.articlePlan(article), sourceText: article).isEmpty)
    }

    func testAPreparationOfThePlainPlanIsNeverMatchedToTheNotesPlan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plain = try await prepare(fixture, coordinator: coordinator, asides: false)
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: PreparedAudioCoordinator.manifestId(itemId: "item", signature: signature())))
        XCTAssertEqual(manifest.articleIdentity, NarrationChunkPlanner.identity(ofArticle: article))
        XCTAssertFalse(NarrationChunkPlanner.usesAsides(identity: manifest.articleIdentity, ofArticle: article))
        let inline = PreparedChunkPlan.articlePlan(article, asides: true)
        XCTAssertTrue(PreparedAudioCoordinator.matchingChunks(in: manifest, plan: inline, sourceText: article, asides: true).isEmpty)
        for entry in inline {
            let found = try await coordinator.committedChunk(itemId: "item", signature: signature(), plan: entry, sourceText: article, asides: true)
            XCTAssertNil(found, "chunk \(entry.index): the notes plan finds none of the plain plan's audio")
        }
        XCTAssertEqual(PreparedAudioCoordinator.matchingChunks(in: manifest, plan: plain, sourceText: article).count, plain.count)
    }

    func testBeginningTheOtherPlanKindReplacesThePreparationInsteadOfResumingIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        _ = try await prepare(fixture, coordinator: coordinator, asides: false)
        let inline = PreparedChunkPlan.articlePlan(article, asides: true)
        let begun = try await coordinator.begin(itemId: "item", sourceText: article, signature: signature(), plan: inline, asides: true)
        XCTAssertEqual(begun.articleIdentity, NarrationChunkPlanner.identity(ofArticle: article, asides: true))
        XCTAssertTrue(begun.chunks.isEmpty, "none of the plain plan's chunks is carried over")
        XCTAssertEqual(begun.plannedChunkCount, inline.count)
    }

    func testAssemblyReadsEachNoteWhereItIsCitedAndLeavesItsDefinitionOut() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = try await prepare(fixture, coordinator: coordinator, asides: true)
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: PreparedAudioCoordinator.manifestId(itemId: "item", signature: signature())))
        let chunks = try PreparedAudioCoordinator.assemblyChunks(plan: plan, manifest: manifest, sourceText: article,
                                                                 preparedRoot: fixture.prepared, asides: true)
        let definitions = plan.filter { if case .definition? = $0.footnote { true } else { false } }
        let asides = plan.filter { if case .aside? = $0.footnote { true } else { false } }
        XCTAssertFalse(definitions.isEmpty)
        XCTAssertFalse(asides.isEmpty)
        XCTAssertEqual(chunks.count, plan.count - definitions.count)
        XCTAssertEqual(Set(chunks.map(\.text)).intersection(definitions.map(\.text)), [], "a note is not read a second time in the notes")
        XCTAssertTrue(asides.allSatisfy { aside in chunks.contains { $0.text == aside.text && $0.sourceLength == 0 } })
        XCTAssertEqual(chunks.map(\.startOffset), chunks.map(\.startOffset).sorted(), "plan order is offset order")
        let order = plan.filter { entry in
            if case .definition? = entry.footnote { return false }
            return true
        }.map(\.text)
        XCTAssertEqual(chunks.map(\.text), order, "an aside stays in front of the sentence that starts where it does")
        XCTAssertThrowsError(try PreparedAudioCoordinator.assemblyChunks(
            plan: PreparedChunkPlan.articlePlan(article), manifest: manifest, sourceText: article,
            preparedRoot: fixture.prepared, asides: false), "the plain plan finds nothing to assemble in the notes plan's manifest")
    }

    func testThePlanCacheHoldsOneKindOfOneTextAtATime() {
        let cache = PreparedChunkPlanCache()
        var builds = 0
        func value(asides: Bool) -> [PreparedChunkPlan] {
            cache.value(for: article, asides: asides) {
                builds += 1
                return PreparedChunkPlan.articlePlan(article, asides: asides)
            }
        }
        XCTAssertEqual(value(asides: false), value(asides: false))
        XCTAssertEqual(builds, 1)
        XCTAssertNotEqual(value(asides: true), value(asides: false))
        XCTAssertEqual(builds, 3, "the other kind of the same text is another plan")
    }

    func testTheDecisionFollowsTheSettingTheItemAndWhatIsAlreadyPrepared() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(PreparedSpeechHooks.footnoteAsides(item: fixture.item, articleText: article, store: fixture.store),
                      "nothing stored: where cited, for a new listener and an old one")
        UserDefaults.standard.set(FootnoteMode.atEnd.rawValue, forKey: FootnoteMode.storageKey)
        XCTAssertFalse(PreparedSpeechHooks.footnoteAsides(item: fixture.item, articleText: article, store: fixture.store))
        UserDefaults.standard.set(FootnoteMode.whereCited.rawValue, forKey: FootnoteMode.storageKey)
        var pdf = fixture.item
        pdf.mediaType = "pdf"
        XCTAssertFalse(PreparedSpeechHooks.footnoteAsides(item: pdf, articleText: article, store: fixture.store), "PDFs keep today's plan")
        XCTAssertFalse(PreparedSpeechHooks.footnoteAsides(item: fixture.item, articleText: "Plain prose with no note.", store: fixture.store))
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        _ = try await prepare(fixture, coordinator: coordinator, asides: false)
        XCTAssertFalse(PreparedSpeechHooks.footnoteAsides(item: fixture.item, articleText: article, store: fixture.store),
                       "audio prepared with the notes at the end keeps them there until it is prepared again")
    }

    /// "Chime where cited" on an article that is ready offline: the file is assembled from the notes plan as
    /// `finishBackgroundPreparedAudio` does it and saved as `PreparedTextAudioPersister` saves it, and the media player's
    /// footnote session is loaded from the store the way the app loads it. A file whose timeline lost the notes' own
    /// segments, or a session read from the wrong text, would load nothing and the notes would play in full (#3777).
    func testAnAssembledFileOfTheNotesPlanLoadsAFootnoteSessionFromTheStore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = try await assembleNotesFile(fixture)

        let session = try XCTUnwrap(Gate1AppModel.loadFootnoteMediaChimeSession(store: fixture.store, itemId: "item", mediaKey: file.mediaKey),
                                    "the assembled file reads each note in its own segment, so the session finds them")
        XCTAssertEqual(session.runStartsMs.count, 2, "the fixture cites two notes in two places")
        XCTAssertNil(Gate1AppModel.loadFootnoteMediaChimeSession(store: fixture.store, itemId: "item", mediaKey: "file:///another.m4a"),
                     "a session is only for the file the item holds")
    }

    /// "Chime where cited" on an article that is ready offline, through the app's own clock handler
    /// (`observeFootnoteMediaChime`, called on every playback tick): the model builds the footnote session for the
    /// prepared file it sees playing, and when playback runs on into a note it sounds the tone and moves the file past
    /// the note's words. A seek that lands inside a note passes over it without the tone (#3777). Before #5081 this path
    /// read every note in full; a session that is never built, or a tick that never reaches it, would fail here.
    @MainActor
    func testChimeModeOnAPreparedFileCuesANoteAndMovesPastItThroughTheModelsClock() async throws {
        UserDefaults.standard.set(FootnoteMode.chime.rawValue, forKey: FootnoteMode.storageKey)
        let root = try makeRoot()
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: root.appending(path: "store.sqlite"))
        let fixture = try makeFixture(root: root, store: model.libraryStoreForTesting())
        addTeardownBlock { [weak model] in
            if model == nil { try? FileManager.default.removeItem(at: root) }
        }
        let file = try await assembleNotesFile(fixture)
        try await pollUntil(timeout: .seconds(10)) { UIApplication.shared.applicationState == .active }
        XCTAssertEqual(UIApplication.shared.applicationState, .active,
                       "app-hosted tests run in the foreground; a note is cued only while the listener can tap")

        var playing = model.snapshot
        playing.itemId = "item"
        playing.targetType = TargetType.transcriptBackedMedia.rawValue
        playing.targetId = file.mediaKey
        playing.preparedTextAudioStatus = "ready"
        playing.status = .playing
        playing.currentMediaTimeMs = 0
        model.observeFootnoteMediaChime(playing)
        try await pollUntil { model.footnoteMediaChime.session != nil }
        let session = try XCTUnwrap(model.footnoteMediaChime.session, "the first tick of the prepared file builds its footnote session")
        XCTAssertTrue(session.plays(itemId: "item", mediaKey: file.mediaKey))
        XCTAssertEqual(session.runStartsMs.count, 2)

        func events(_ kind: String) -> [[String: String]] {
            model.playbackEventRecording.events.filter { $0.kind == kind }.map(\.fields)
        }
        func tick(atMs ms: Int) {
            playing.currentMediaTimeMs = ms
            model.observeFootnoteMediaChime(playing)
        }

        // Playback runs on, one segment at a time, up to the first note.
        let starts = file.timeline.segments.map(\.startMs)
        let firstNote = try XCTUnwrap(starts.firstIndex(of: session.runStartsMs[0]))
        for index in 0..<firstNote {
            tick(atMs: starts[index])
            XCTAssertTrue(events("footnote.media.move").isEmpty, "the text before the note plays on (segment \(index))")
        }
        tick(atMs: starts[firstNote])
        XCTAssertEqual(events("footnote.media.cue").map { $0["label"] }, ["1"], "one tone, for note 1, where it is cited")
        let cueMove = try XCTUnwrap(events("footnote.media.move").last)
        XCTAssertEqual(cueMove["reason"], "cue")
        let landing = try XCTUnwrap(cueMove["timeMs"].flatMap(Int.init))
        XCTAssertGreaterThan(landing, file.timeline.segments[firstNote].endMs, "the move passes over the note's words")
        XCTAssertLessThanOrEqual(landing, starts[firstNote + 1], "and lands no later than the sentence after the citation")

        // The listener seeks into the second note: it passes over silently, with no tone. (Here the cue's move found no
        // engine session and the model already called this; the explicit call keeps the step a listener's seek either way.)
        model.footnoteMediaChime.session?.playerMovedOnItsOwn()
        let secondNote = try XCTUnwrap(starts.firstIndex(of: session.runStartsMs[1]))
        tick(atMs: starts[secondNote])
        XCTAssertEqual(events("footnote.media.cue").count, 1, "a seek into a note sounds no tone")
        let passMove = try XCTUnwrap(events("footnote.media.move").last)
        XCTAssertEqual(passMove["reason"], "pass")
        XCTAssertEqual(passMove["timeMs"].flatMap(Int.init), starts[secondNote + 1], "the file goes on at the sentence after the note")
    }

    /// Assembles the notes plan into one file as `finishBackgroundPreparedAudio` does, saves it as
    /// `PreparedTextAudioPersister` saves it, and returns the file's identity and timeline.
    private func assembleNotesFile(_ fixture: Fixture) async throws -> (mediaKey: String, timeline: TranscriptTimeline) {
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let coordinator = PreparedAudioCoordinator(repository: fixture.store, rootDirectory: fixture.prepared)
        let plan = PreparedChunkPlan.articlePlan(article, asides: true)
        _ = try await coordinator.begin(itemId: "item", sourceText: article, signature: signature(), plan: plan, asides: true)
        for entry in plan {
            try await coordinator.commit(itemId: "item", signature: signature(), plan: entry, sourceText: article,
                                         audioURL: template, durationMs: 200, asides: true)
        }
        let manifest = try XCTUnwrap(fixture.store.loadPreparedAudioManifest(id: PreparedAudioCoordinator.manifestId(itemId: "item", signature: signature())))
        let speech = try XCTUnwrap(PreparedSpeechHooks.texts.resolve(item: fixture.item, documents: fixture.store))
        let narration = try await SupertonicPreparedAudioAssembler.assemble(
            itemId: "item",
            sourceText: speech.itemText,
            projection: speech.assemblyProjection(asides: true),
            voice: .m2,
            chunks: try PreparedAudioCoordinator.assemblyChunks(plan: plan, manifest: manifest, sourceText: article,
                                                               preparedRoot: fixture.prepared, asides: true),
            outputDirectory: fixture.root.appending(path: "Narration", directoryHint: .isDirectory)
        )
        try fixture.store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item", itemId: "item", createdAt: narration.createdAt, timeline: narration.timeline))
        var stored = fixture.item
        stored.text = narration.normalizedText
        stored.media = narration.media
        stored.transcriptId = "generated-transcript-item"
        try fixture.store.saveItem(stored)
        return (try XCTUnwrap(narration.media.nativeMediaId), narration.timeline)
    }

    private func makeTestWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "footnote-chunk-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 44_100) * 0.1
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
