import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4339 PR 2: the author's answer to a tidy version of a spoken Margin. Every transition runs against a real SQLite
/// file that is reopened the way a relaunch reopens it. Nothing in the app calls these yet.
final class MarginTidyDecisionTests: XCTestCase {
    private var paths: [String] = []
    private let decidedAt = Date(timeIntervalSince1970: 1_700_000_500)

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    // MARK: Transitions

    func testUsingTheTidyStoresTheTextAndTheAnswerAndLeavesTheTranscriptAlone() throws {
        let path = makePath()
        let (store, engine) = try makeEngine(path: path)
        try store.saveInterjection(margin())

        _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "The result was not 12 percent.", basedOn: Self.spoken, source: .fillers)

        let reopened = try SQLiteSessionStore(path: path)
        let saved = try XCTUnwrap(try reopened.loadInterjections(sessionId: "session-A").first)
        XCTAssertEqual(saved.cleanedTranscript, "The result was not 12 percent.")
        XCTAssertEqual(saved.displayText, "The result was not 12 percent.")
        XCTAssertEqual(saved.transcript, Self.spoken, "the original words are never written")
        XCTAssertEqual(saved.audioPath, "interjections/m1.m4a", "nor is the recording")
        XCTAssertEqual(saved.tidyDecision, MarginTidyDecision(choice: .usedTidy, source: .fillers, decidedAt: decidedAt))
    }

    func testKeepMineAnswersWithoutChangingAnyWordsAndSurvivesARelaunch() throws {
        let path = makePath()
        let (store, engine) = try makeEngine(path: path)
        let before = margin()
        try store.saveInterjection(before)

        _ = try engine.keepOriginal(interjectionId: "m1", sessionId: "session-A")

        var expected = before
        expected.tidyDecision = MarginTidyDecision(choice: .keptOriginal, decidedAt: decidedAt)
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadInterjections(sessionId: "session-A").first, expected)
    }

    func testUseMyOriginalWordsDropsTheTidyTextAndTheAnswerSoTheProposalCanComeBack() throws {
        let path = makePath()
        let (store, engine) = try makeEngine(path: path)
        let before = margin()
        try store.saveInterjection(before)
        _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .onDeviceAI)

        _ = try engine.useOriginalWords(interjectionId: "m1", sessionId: "session-A")

        let saved = try XCTUnwrap(try SQLiteSessionStore(path: path).loadInterjections(sessionId: "session-A").first)
        XCTAssertNil(saved.tidyDecision)
        XCTAssertNil(saved.cleanedTranscript)
        XCTAssertEqual(saved.displayText, Self.spoken, "readers fall back to the transcript")
        XCTAssertEqual(saved, before)
    }

    func testKeepMineDoesNotOverwriteAnApprovedTidyAndUseTidyAfterKeepMineWins() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin())
        _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)
        _ = try engine.keepOriginal(interjectionId: "m1", sessionId: "session-A")
        XCTAssertEqual(try loaded(store).tidyDecision?.choice, .usedTidy, "a stale Keep mine tap does not undo an approval")

        let (store2, engine2) = try makeEngine(path: makePath())
        try store2.saveInterjection(margin())
        _ = try engine2.keepOriginal(interjectionId: "m1", sessionId: "session-A")
        _ = try engine2.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)
        XCTAssertEqual(try loaded(store2).tidyDecision?.choice, .usedTidy, "the listener can change their mind from the details screen")
        XCTAssertEqual(try loaded(store2).displayText, "Tidy.")
    }

    func testANewTranscriptClearsTheTidyAndTheAnswerOnBothTranscriptionPaths() throws {
        for aligned in [false, true] {
            let (store, engine) = try makeEngine(path: makePath())
            try store.saveInterjection(margin())
            _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)

            if aligned {
                let text = AlignedInterjectionTranscript(text: "Fresh words", segments: [])
                _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", alignedTranscript: text)
            } else {
                _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Fresh words")
            }
            let saved = try loaded(store)
            XCTAssertNil(saved.tidyDecision, "aligned: \(aligned)")
            XCTAssertNil(saved.cleanedTranscript, "aligned: \(aligned)")
            XCTAssertEqual(saved.displayText, "Fresh words", "aligned: \(aligned)")
        }
        // Keep mine is cleared with the words it was about.
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin())
        _ = try engine.keepOriginal(interjectionId: "m1", sessionId: "session-A")
        _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Fresh words")
        XCTAssertNil(try loaded(store).tidyDecision)
    }

    func testDeletingTheTranscriptClearsTheAnswerAndDeletingOnlyTheTidyKeepsAKeepMine() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin())
        _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)
        _ = try engine.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "transcript")
        let deleted = try loaded(store)
        XCTAssertNil(deleted.tidyDecision)
        XCTAssertNil(deleted.cleanedTranscript)

        let (store2, engine2) = try makeEngine(path: makePath())
        try store2.saveInterjection(margin())
        _ = try engine2.keepOriginal(interjectionId: "m1", sessionId: "session-A")
        _ = try engine2.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "cleanedTranscript")
        XCTAssertEqual(try loaded(store2).tidyDecision?.choice, .keptOriginal)

        let (store3, engine3) = try makeEngine(path: makePath())
        try store3.saveInterjection(margin())
        _ = try engine3.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)
        _ = try engine3.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "cleanedTranscript")
        XCTAssertNil(try loaded(store3).tidyDecision, "a used tidy with no tidy text would be a contradiction")
    }

    func testAnApprovalAfterTheTranscriptWasDeletedWritesNothing() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin())
        _ = try engine.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "transcript")
        let afterDelete = try loaded(store)
        _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)
        XCTAssertEqual(try loaded(store), afterDelete, "a proposal made before Delete Transcript cannot bring words back")

        var noTranscript = margin()
        noTranscript.id = "m2"
        noTranscript.transcript = nil
        noTranscript.displayText = nil
        noTranscript.cleanedTranscript = nil
        try store.saveInterjection(noTranscript)
        _ = try engine.useTidy(interjectionId: "m2", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first { $0.id == "m2" }, noTranscript)
    }

    func testAnApprovalOfAProposalMadeFromOtherWordsWritesNothing() throws {
        // Delete Transcript, Retry, a new transcript lands, then the tap on the old card: the Margin has words, so a
        // "has a transcript" check passes, but they are not the words the tidy version was made from.
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin())
        _ = try engine.deleteRepresentation(interjectionId: "m1", sessionId: "session-A", representation: "transcript")
        _ = try engine.transcriptionRequested(interjectionId: "m1", sessionId: "session-A")
        _ = try engine.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Fresh words")
        let afterRetry = try loaded(store)

        _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)

        XCTAssertEqual(try loaded(store), afterRetry, "a tidy of old words is never saved onto the new transcript")

        // The same without a delete: a new transcription lands between showing the proposal and the tap.
        let (store2, engine2) = try makeEngine(path: makePath())
        try store2.saveInterjection(margin())
        _ = try engine2.transcriptionCompleted(interjectionId: "m1", sessionId: "session-A", transcript: "Fresh words")
        let afterNew = try loaded(store2)
        _ = try engine2.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .onDeviceAI)
        XCTAssertEqual(try loaded(store2), afterNew)

        // A proposal made from the words the Margin has now still goes through.
        _ = try engine2.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy fresh words.", basedOn: "Fresh words", source: .onDeviceAI)
        XCTAssertEqual(try loaded(store2).displayText, "Tidy fresh words.")
    }

    func testAnAnswerOnOneMarginLeavesTheOthersAndTheSameIdInAnotherSessionAlone() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin())
        var other = margin(id: "m2")
        other.sessionId = "session-B"
        try store.saveInterjection(other)
        var sameId = margin()
        sameId.sessionId = "session-B"
        try store.saveInterjection(sameId)

        _ = try engine.useTidy(interjectionId: "m1", sessionId: "session-A", text: "Tidy.", basedOn: Self.spoken, source: .fillers)

        XCTAssertNil(try store.loadInterjections(sessionId: "session-B").first { $0.id == "m2" }?.tidyDecision)
        XCTAssertNil(try store.loadInterjections(sessionId: "session-B").first { $0.id == "m1" }?.tidyDecision)
    }

    // MARK: Shape

    func testTheAnswerIsFlatJSONWithStringValuesAndAMarginWithoutOneWritesNoKey() throws {
        var decided = margin()
        decided.tidyDecision = MarginTidyDecision(choice: .usedTidy, source: .onDeviceAI, decidedAt: decidedAt)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.isoEncoder.encode(decided)) as? [String: Any])
        let answer = try XCTUnwrap(object["tidyDecision"] as? [String: Any])
        XCTAssertEqual(answer["choice"] as? String, "usedTidy")
        XCTAssertEqual(answer["source"] as? String, "onDeviceAI")
        XCTAssertEqual(Set(answer.keys), ["choice", "source", "decidedAt"])
        XCTAssertTrue(answer.values.allSatisfy { $0 is String }, "no nested containers or numbers an older reader could trip on")

        let kept = MarginTidyDecision(choice: .keptOriginal, decidedAt: decidedAt)
        let keptObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.isoEncoder.encode(kept)) as? [String: Any])
        XCTAssertEqual(Set(keptObject.keys), ["choice", "decidedAt"])

        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.isoEncoder.encode(margin())) as? [String: Any])
        XCTAssertNil(plain["tidyDecision"], "a Margin never asked about writes the same row as before this field")
    }

    func testAMarginRowWrittenBeforeTheFieldDecodesWithNoAnswerAndOneWithAnAnswerStillRoundTrips() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.isoEncoder.encode(margin())) as? [String: Any])
        object.removeValue(forKey: "tidyDecision")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try Self.isoDecoder.decode(Interjection.self, from: legacy).tidyDecision)

        var decided = margin()
        decided.tidyDecision = MarginTidyDecision(choice: .usedTidy, source: .fillers, decidedAt: decidedAt)
        let data = try Self.isoEncoder.encode(decided)
        XCTAssertEqual(try Self.isoDecoder.decode(Interjection.self, from: data), decided)
    }

    // MARK: Sync

    func testTheAnswerTravelsAsOneRegisterAndAClearedAnswerReachesTheOtherPhone() throws {
        var clock = SyncClock(device: "A")
        var decided = margin()
        decided.tidyDecision = MarginTidyDecision(choice: .keptOriginal, decidedAt: decidedAt)
        var record = try MarginSync.record(for: decided, itemKey: "ep-1", clock: &clock, wallMillis: 1_000)
        XCTAssertNotNil(record["tidyDecision"])
        XCTAssertTrue(SyncFieldSchema.isEncrypted(field: "tidyDecision"), "what the listener decided about their words is private")

        let onOtherPhone = MarginSync.apply(record, to: margin())
        XCTAssertEqual(onOtherPhone.tidyDecision, decided.tidyDecision)

        var used = decided
        used.tidyDecision = MarginTidyDecision(choice: .usedTidy, source: .fillers, decidedAt: decidedAt)
        used.cleanedTranscript = "Tidy."
        used.displayText = "Tidy."
        MarginSync.write(used, changedFrom: decided, into: &record, clock: &clock, wallMillis: 2_000)
        let usedOnOtherPhone = MarginSync.apply(record, to: onOtherPhone)
        XCTAssertEqual(usedOnOtherPhone.tidyDecision, used.tidyDecision)
        XCTAssertEqual(usedOnOtherPhone.cleanedTranscript, "Tidy.")

        // Use my original words: the answer and the tidy text go, the transcript shows again.
        var cleared = used
        cleared.tidyDecision = nil
        cleared.cleanedTranscript = nil
        cleared.displayText = used.transcript
        MarginSync.write(cleared, changedFrom: used, into: &record, clock: &clock, wallMillis: 3_000)
        let clearedOnOtherPhone = MarginSync.apply(record, to: usedOnOtherPhone)
        XCTAssertNil(clearedOnOtherPhone.tidyDecision, "Use my original words on one phone clears it on the other")
        XCTAssertNil(clearedOnOtherPhone.cleanedTranscript, "readers that prefer the cleaned text would otherwise show the tidy words again")
        XCTAssertEqual(clearedOnOtherPhone.displayText, Self.spoken)
    }

    func testAnUntouchedAnswerIsNotWrittenAndARecordWithoutOneLeavesTheDevicesAnswerAlone() throws {
        var clock = SyncClock(device: "A")
        var decided = margin()
        decided.tidyDecision = MarginTidyDecision(choice: .keptOriginal, decidedAt: decidedAt)
        var record = SyncRecord(id: .margin("m1"), schemaVersion: MarginSync.schemaVersion)
        var edited = decided
        edited.privateSharingNote = "for Sam"
        MarginSync.write(edited, changedFrom: decided, into: &record, clock: &clock, wallMillis: 1_000)
        XCTAssertNil(record["tidyDecision"], "only what the listener changed is written, so a remote answer is not replaced by a stale copy")
        XCTAssertEqual(MarginSync.apply(record, to: decided).tidyDecision, decided.tidyDecision)

        record.set("tidyDecision", .string("a shape from a newer reading"), clock: &clock, wallMillis: 2_000)
        XCTAssertEqual(MarginSync.apply(record, to: decided).tidyDecision, decided.tidyDecision, "an answer this build cannot read is left as it is")
    }

    // MARK: Helpers

    private static var isoEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var isoDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static let spoken = "um so the the result was not 12 percent"

    private func loaded(_ store: SQLiteSessionStore) throws -> Interjection {
        try XCTUnwrap(try store.loadInterjections(sessionId: "session-A").first { $0.id == "m1" })
    }

    private func makePath() -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-margin-tidy-\(UUID().uuidString).sqlite").path
        paths.append(path)
        return path
    }

    private func makeEngine(path: String) throws -> (SQLiteSessionStore, SessionEngine) {
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-text", title: "Text", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        try store.saveItem(item)
        for id in ["session-A", "session-B"] {
            try store.saveSession(Session(
                id: id, itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1
            ))
        }
        let when = decidedAt
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone / Tablet Online", capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"],
            ]),
            repository: store,
            now: { when }
        )
        return (store, engine)
    }

    private func margin(id: String = "m1") -> Interjection {
        Interjection(
            id: id, itemId: "item-text", sessionId: "session-A", targetType: .item, targetId: "item-text",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: "interjections/\(id).m4a", audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: Self.spoken, cleanedTranscript: nil, displayText: Self.spoken, status: "active"
        )
    }
}
