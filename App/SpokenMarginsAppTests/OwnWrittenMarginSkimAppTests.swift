import AVFoundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #4938: Skim stops at the listener's own written Margins (a Lock Screen Mark, a Siri note, a typed note) the way it stops at a
/// friend's silent Margin (#4934): the source moves to the note's place, with no lead-in and no voice, plays on, and the card on
/// Now says "Your Margin is here" with its words. A burst of notes takes one press; a go-to from a list sets the same landing.
@MainActor
final class OwnWrittenMarginSkimAppTests: XCTestCase {
    private func skimOutcomes(_ model: Gate1AppModel) -> [String] {
        model.playbackEventRecording.events.filter { $0.kind == "skim.press" }.compactMap { $0.fields["outcome"] }
    }

    private func ownWrittenPresses(_ model: Gate1AppModel) -> Int {
        skimOutcomes(model).filter { $0 == "went_to_own_written_margin" }.count
    }

    /// The fixture's 30 s source with no friend's Margin, paused at `atMs`.
    private func pausedFixture(atMs: Int) async throws -> ReturnFixture {
        let fixture = try await ReturnFixture.make(sourcePlaying: false, withFriendRecord: false)
        let model = fixture.model
        XCTAssertTrue(model.selectedItem.mediaChapters.isEmpty && model.selectedItem.listeningMapScenes.isEmpty,
                      "no chapter or scene stands between the notes")
        model.sharedMarginRows = []
        model.pause()
        model.seekMedia(toMediaTimeMs: atMs)
        try await fixture.waitUntil("the source is paused at \(atMs) ms") {
            abs((model.snapshot.currentMediaTimeMs ?? -10_000) - atMs) < 500
        }
        return fixture
    }

    /// One of the listener's own written Margins at `atMs`, in the store and then in the rows Skim reads.
    private func addNote(_ fixture: ReturnFixture, id: String, atMs: Int, words: String? = nil) throws {
        try fixture.addOwnWrittenMargin(id: id, atMediaTimeMs: atMs, words: words ?? "My note \(id)")
        fixture.model.refreshMarginRows()
    }

    private func assertYourCard(_ model: Gate1AppModel, words: String, line: UInt = #line) {
        guard let card = model.pinnedMarginCard else { return XCTFail("no card", line: line) }
        XCTAssertEqual(card.subject, .yours, line: line)
        XCTAssertEqual(card.stage, .silentHere(words: words, isApproximate: false), line: line)
        XCTAssertEqual(card.headline, "Your Margin is here", line: line)
    }

    // Done when 3: fails on the `main` this branched from, where Skim keeps only spoken own Margins
    // (`Gate1AppModel+SkimStops.swift`, `isSpokenItemMargin`) and the press finds nowhere to go.
    func testSkimForwardFromBeforeAnOwnWrittenMarginLandsAtItsPlace() async throws {
        let fixture = try await pausedFixture(atMs: 2_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try addNote(fixture, id: "note-10", atMs: 10_000, words: "Come back to this")
        try await pollUntil { model.marginRows.contains { $0.interjection.id == "note-10" } }

        model.skimForward()
        defer { model.pause() }
        try await fixture.waitUntil("the source is at the note and playing") {
            abs((model.snapshot.currentMediaTimeMs ?? 0) - 10_000) <= 2_000 && model.snapshot.status == .playing
        }
        XCTAssertNil(model.marginMoment, "a written note starts no moment")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(skimOutcomes(model).last, "went_to_own_written_margin")
        assertYourCard(model, words: "Come back to this")
    }

    func testSkimBackTwiceDoesNotRepeatAnOwnWrittenStop() async throws {
        let fixture = try await pausedFixture(atMs: 25_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try addNote(fixture, id: "note-5", atMs: 5_000)
        try await pollUntil { model.marginRows.contains { $0.interjection.id == "note-5" } }

        model.skimBackward()
        defer { model.pause() }
        try await fixture.waitUntil("Skim has gone back to the note") { (model.snapshot.currentMediaTimeMs ?? Int.max) < 8_000 }
        XCTAssertEqual(ownWrittenPresses(model), 1)

        model.skimBackward()
        XCTAssertEqual(ownWrittenPresses(model), 1, "the second press does not land on the same note again: \(skimOutcomes(model))")
    }

    func testABurstOfNotesTakesOnePressAndTheCardFollowsThem() async throws {
        let fixture = try await pausedFixture(atMs: 2_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try addNote(fixture, id: "a", atMs: 4_000, words: "First")
        try addNote(fixture, id: "b", atMs: 7_000, words: "Second")
        try addNote(fixture, id: "c", atMs: 10_000, words: "Third")
        try await pollUntil { model.marginRows.filter { ["a", "b", "c"].contains($0.interjection.id) }.count == 3 }

        model.skimForward()
        defer { model.pause() }
        try await fixture.waitUntil("the source is at the first note") {
            abs((model.snapshot.currentMediaTimeMs ?? 0) - 4_000) <= 2_000 && model.silentMarginLanding != nil
        }
        XCTAssertEqual(model.silentMarginLanding?.notes.map(\.marginId), ["a", "b", "c"])
        XCTAssertEqual(ownWrittenPresses(model), 1)

        model.seekMedia(toMediaTimeMs: 7_500)
        try await fixture.waitUntil("the source is past the second note") {
            (model.snapshot.currentMediaTimeMs ?? 0) >= 7_000 && (model.snapshot.currentMediaTimeMs ?? 0) < 10_000
        }
        assertYourCard(model, words: "Second")

        model.skimForward()
        XCTAssertEqual(ownWrittenPresses(model), 1, "the next press goes past every gathered note: \(skimOutcomes(model))")
    }

    func testSkimForwardOnAnArticleLandsAtAnOwnWrittenMargin() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "own-written-article-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        defer { model.pause() }
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let sentence = { (number: Int) in String(format: "Sentence %02d is one small thing to hear. ", number) }
        let text = (0..<80).map(sentence).joined()
        try store.saveItem(Item(id: "own-article", title: "Own article", mediaType: "text", text: text,
            externalReference: "local", status: "ready"))
        model.startItem(id: "own-article")
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue, "read aloud on the device")
        let targetChar = sentence(0).count * 40
        let note = Interjection(
            id: "article-note", itemId: "own-article", sessionId: try XCTUnwrap(model.snapshot.sessionId),
            targetType: .item, targetId: "own-article", createdAt: Date(), roughPercent: 50,
            anchor: Anchor(anchorType: .text, startChar: targetChar, endChar: targetChar + sentence(0).count, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "A line to keep",
            cleanedTranscript: nil, displayText: "A line to keep", status: "active", captureKind: .written)
        try store.saveInterjection(note)
        model.refreshMarginRows()
        try await pollUntil { model.marginRows.contains { $0.interjection.id == "article-note" } }
        model.seekText(toCharOffset: 0)

        model.skimForward()
        // Reading carries on from the note's sentence, so the place may already be a sentence or two on.
        let sentences = sentence(0).count
        try await pollUntil { (model.snapshot.currentTextStart ?? 0) >= targetChar }
        XCTAssertLessThan(model.snapshot.currentTextStart ?? .max, targetChar + 3 * sentences, "at the note, not past it")
        XCTAssertEqual(skimOutcomes(model).last, "went_to_own_written_margin")
        assertYourCard(model, words: "A line to keep")
    }

    func testASpokenMarginAfterAWrittenStopStillGetsItsMoment() async throws {
        let fixture = try await pausedFixture(atMs: 1_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try addNote(fixture, id: "note-5", atMs: 5_000)
        let spoken = try fixture.addOwnMargin(id: "spoken-20", atMediaTimeMs: 20_000, voiceSeconds: 1)
        model.refreshMarginRows()
        try await pollUntil { model.marginRows.filter { ["note-5", "spoken-20"].contains($0.interjection.id) }.count == 2 }

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        try await fixture.waitUntil("the source is at the note") {
            abs((model.snapshot.currentMediaTimeMs ?? 0) - 5_000) <= 2_000 && model.shownSilentMarginLanding != nil
        }
        model.skimForward()
        // A moment names its Margin by identity (session and id, `Gate1AppModel.marginIdentity`), never by the bare id (#5428).
        let identity = Gate1AppModel.marginIdentity(spoken)
        try await fixture.waitUntil("the spoken Margin's moment has started") { model.marginMoment?.target.marginId == identity }
        XCTAssertGreaterThanOrEqual(model.snapshot.currentMediaTimeMs ?? 0, 4_000, "never back before the note")
    }

    func testAWrittenStopAfterASpokenMomentStillShowsTheCard() async throws {
        let fixture = try await pausedFixture(atMs: 500)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let spoken = try fixture.addOwnMargin(id: "spoken-3", atMediaTimeMs: 3_000, voiceSeconds: 1)
        try addNote(fixture, id: "note-15", atMs: 15_000, words: "After the voice")
        try await pollUntil { model.marginRows.filter { ["spoken-3", "note-15"].contains($0.interjection.id) }.count == 2 }

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        let identity = Gate1AppModel.marginIdentity(spoken)
        try await fixture.waitUntil("the spoken Margin's voice has the floor", timeout: 15) {
            model.marginMoment?.isPlayingMargin == true && model.marginMoment?.playing?.marginId == identity
        }
        // The note is a silent stop, never one of the moment's inline Margins, so once the voice ends nothing is left to play
        // inline and the moment ends (`startMarginMoment`'s `onChange`). It never sits listening here (#5428).
        try await fixture.waitUntil("the spoken Margin has played and its moment has ended", timeout: 15) { model.marginMoment == nil }
        model.skimForward()
        try await fixture.waitUntil("the source is at the note") {
            abs((model.snapshot.currentMediaTimeMs ?? 0) - 15_000) <= 2_000 && model.shownSilentMarginLanding != nil
        }
        assertYourCard(model, words: "After the voice")
    }

    func testAGoToOnAnOwnWrittenMarginKeepsBackFromLandingOnItAgain() async throws {
        let fixture = try await pausedFixture(atMs: 1_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try addNote(fixture, id: "note-10", atMs: 10_000, words: "Gone to")
        try await pollUntil { model.marginRows.contains { $0.interjection.id == "note-10" } }
        let row = try XCTUnwrap(model.marginRows.first { $0.interjection.id == "note-10" })

        MarginMomentTap.start(row, model: model)
        defer { model.pause() }
        try await fixture.waitUntil("the go-to set the landing") { model.shownSilentMarginLanding?.marginId == "note-10" }
        assertYourCard(model, words: "Gone to")
        if model.snapshot.status != .playing { model.resumePlayback() }
        try await fixture.waitUntil("playback passed 13 s", timeout: 10) { (model.snapshot.currentMediaTimeMs ?? 0) > 13_000 }

        model.skimBackward()
        XCTAssertEqual(ownWrittenPresses(model), 0, "the landing guards the note it went to: \(skimOutcomes(model))")
    }

    func testAWrittenMarginThatArrivesLateBecomesAStop() async throws {
        let fixture = try await pausedFixture(atMs: 2_000)
        defer { fixture.cleanUp() }
        let model = fixture.model
        XCTAssertEqual(model.skimStopList?.stops.count ?? 0, 0, "nothing ahead before the note arrives")

        try addNote(fixture, id: "late", atMs: 12_000)
        try await pollUntil { model.skimStopList?.stops.contains { $0.id == "late" && $0.isOwnWritten } == true }
        try await pollUntil { model.snapshot.canSkimForward }
        XCTAssertTrue(model.snapshot.canSkimForward, "the forward arrow turns bright once the note is a stop")

        model.skimForward()
        defer { model.pause() }
        try await fixture.waitUntil("the source is at the late note") { abs((model.snapshot.currentMediaTimeMs ?? 0) - 12_000) <= 2_000 }
        XCTAssertEqual(skimOutcomes(model).last, "went_to_own_written_margin")
    }

    func testAFriendsSilentMarginAndYourNoteAtOnePlaceAreOneStop() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: false, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.sharedMarginRows = [SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")]
        model.pause()
        model.seekMedia(toMediaTimeMs: 100)
        try await fixture.waitUntil("the source is before both") { (model.snapshot.currentMediaTimeMs ?? Int.max) < 900 }
        try addNote(fixture, id: "mine", atMs: 1_500) // the friend's Margin is at 1 s
        try await pollUntil { model.marginRows.contains { $0.interjection.id == "mine" } }
        XCTAssertEqual(model.skimStopList?.stops.map(\.id), [fixture.record.id], "your note is dropped on the tie")

        model.skimForward()
        defer { model.pause() }
        try await fixture.waitUntil("the source is at the friend's Margin") { model.silentMarginLanding != nil }
        XCTAssertEqual(skimOutcomes(model).last, "went_to_silent_margin")
        XCTAssertEqual(model.silentMarginLanding?.marginId, fixture.record.id, "the card is the friend's")
    }
}
