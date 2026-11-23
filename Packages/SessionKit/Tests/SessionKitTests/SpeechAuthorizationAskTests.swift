#if canImport(Speech)
import Speech
import XCTest
import SessionKit
@testable import SessionKitAudio

/// #4715 PR 1 / #5016: both transcription clients ask iOS for Speech Recognition whenever the answer is open, which is
/// the surprise prompt on a first save. They now go through one gate that only asks after the listener's Yes.
final class SpeechAuthorizationAskTests: XCTestCase {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func record() { lock.withLock { calls += 1 } }
    }

    private func outcome(
        current: SFSpeechRecognizerAuthorizationStatus, mayAsk: Bool, answer: SFSpeechRecognizerAuthorizationStatus = .authorized
    ) async -> (error: String?, requests: Int) {
        let requests = Requests()
        do {
            try await SpeechAuthorizationAsk.requireAuthorized(for: .episodeMap, current: current, mayAskSystem: mayAsk, reportHold: { _ in }) {
                requests.record()
                return answer
            }
            return (nil, requests.count)
        } catch {
            return (String(describing: error), requests.count)
        }
    }

    /// `heldWhileUnanswered`
    func testHeldWhileUnanswered() async {
        let result = await outcome(current: .notDetermined, mayAsk: false)
        XCTAssertEqual(result.requests, 0, "iOS's prompt must not be requested before the listener's Yes")
        XCTAssertEqual(
            result.error,
            String(describing: SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionNotYetAskedError)))
        XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: result.error ?? ""))
        XCTAssertFalse(TranscriptionFailureWording.isSpeechRecognitionOff(error: result.error ?? ""))
    }

    func testAfterYesTheSystemIsAskedOnceAndItsAnswerDecides() async {
        let allow = await outcome(current: .notDetermined, mayAsk: true, answer: .authorized)
        XCTAssertEqual(allow.requests, 1)
        XCTAssertNil(allow.error)

        let deny = await outcome(current: .notDetermined, mayAsk: true, answer: .denied)
        XCTAssertEqual(deny.requests, 1)
        XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionOff(error: deny.error ?? ""))
    }

    /// Neighbouring inputs: a decided answer is never re-requested, with the gate open or shut.
    func testADecidedAnswerNeverRequestsAnything() async {
        let table: [(SFSpeechRecognizerAuthorizationStatus, Bool, expectsError: Bool)] = [
            (.authorized, false, false), (.authorized, true, false),
            (.denied, false, true), (.denied, true, true),
            (.restricted, false, true), (.restricted, true, true)
        ]
        for (status, mayAsk, expectsError) in table {
            let result = await outcome(current: status, mayAsk: mayAsk)
            XCTAssertEqual(result.requests, 0, "\(status.rawValue) mayAsk=\(mayAsk)")
            XCTAssertEqual(result.error != nil, expectsError, "\(status.rawValue) mayAsk=\(mayAsk)")
            if let error = result.error {
                XCTAssertTrue(TranscriptionFailureWording.isSpeechRecognitionOff(error: error), "a decided no is today's wording")
            }
        }
    }

    private func thrown(current: SFSpeechRecognizerAuthorizationStatus, mayAsk: Bool) async -> Error? {
        do {
            try await SpeechAuthorizationAsk.requireAuthorized(for: .episodeMap, current: current, mayAskSystem: mayAsk, reportHold: { _ in }) { .authorized }
            return nil
        } catch {
            return error
        }
    }

    /// Each caller that meets the hold names it with `HeldTranscription.isHold` on the error the gate throws (#4715), so
    /// it can make the ask owed and be retried after Allow. Only the open-and-unasked case is a hold; a decided no and an
    /// allowed answer are not.
    func testOnlyTheOpenAndUnaskedCaseIsAHoldACallerCanName() async {
        let held = await thrown(current: .notDetermined, mayAsk: false)
        XCTAssertTrue(held.map(HeldTranscription.isHold) ?? false)
        let allowed = await thrown(current: .authorized, mayAsk: false)
        XCTAssertNil(allowed, "iOS already authorizes: never held")
        for denied in [SFSpeechRecognizerAuthorizationStatus.denied, .restricted] {
            let error = await thrown(current: denied, mayAsk: false)
            XCTAssertFalse(error.map(HeldTranscription.isHold) ?? true, "a decided no is not a hold")
        }
    }

    /// Nothing in this process closes the gate, so a macOS tool or test that has no card still asks iOS as it always did.
    func testTheGateIsOpenUntilTheAppClosesIt() {
        XCTAssertTrue(SpeechAuthorizationAsk.mayAskSystem())
    }
}

/// The audit on #5124 (18:59Z): spoken Margins from a live session, the Watch or the Shortcut met the hold behind a `try?`
/// and nothing armed the card or retried them. The gate now reports every hold, with what it held, to one sink.
final class SpeechHoldReachesTheAskTests: XCTestCase {
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Every purpose is reported when held, and only then: an allowed or decided answer reports nothing.
    func testTheGateReportsEachHoldWithItsPurposeAndNothingElse() async {
        let reported = Box<[HeldTranscription]>([])
        let sink: @Sendable (HeldTranscription) -> Void = { purpose in reported.value.append(purpose) }
        for purpose in HeldTranscription.allCases {
            _ = try? await SpeechAuthorizationAsk.requireAuthorized(
                for: purpose, current: .notDetermined, mayAskSystem: false, reportHold: sink) { .authorized }
        }
        XCTAssertEqual(reported.value, HeldTranscription.allCases, "each hold names what it held")

        let decided: [(SFSpeechRecognizerAuthorizationStatus, Bool)] = [
            (.authorized, false), (.authorized, true), (.denied, false), (.denied, true), (.restricted, false), (.restricted, true),
            (.notDetermined, true), // the listener said Yes: iOS is asked, and its Allow is no hold
        ]
        for (status, mayAsk) in decided {
            _ = try? await SpeechAuthorizationAsk.requireAuthorized(
                for: .liveSessionMargin, current: status, mayAskSystem: mayAsk, reportHold: sink) { .authorized }
        }
        XCTAssertEqual(reported.value.count, HeldTranscription.allCases.count, "only a hold is reported")
    }

    /// A listener who never records in the player records a spoken Margin in a live session. Its transcription meets the
    /// hold behind `try?` (as `LiveSessionSpokenMargins.transcribe`); the gate's report alone makes the card owed, in the
    /// Margins words, and after Allow the Margin gets its words from the live-session sweep.
    @MainActor
    func testAHeldLiveSessionMarginIsOwedAndTranscribedAfterAllow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "held-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = LiveSessionFileWorker(root: root)
        let filed = await worker.fileSpokenMarginAsQuick(
            marginId: "phone-1", audioPath: "interjections/phone-1.m4a", markedAt: Date(timeIntervalSince1970: 1_000),
            durationMs: 2_000, spokenOn: "phone")
        let sessionId = try XCTUnwrap(filed?.id)

        let status = Box<SFSpeechRecognizerAuthorizationStatus>(.notDetermined)
        let reported = Box<[HeldTranscription]>([])
        let transcribe: @Sendable (String) async -> String? = { _ in
            let allowed: Void? = try? await SpeechAuthorizationAsk.requireAuthorized(
                for: .liveSessionMargin, current: status.value, mayAskSystem: false,
                reportHold: { purpose in reported.value.append(purpose) }) { .notDetermined }
            return allowed.map { "my words" }
        }
        // The app's sink (`SpeechAskController.holdReported`): the ask decides owed, the retries keep the sweep.
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        let sweep = Box<Task<[String], Never>?>(nil)
        let retries = HeldTranscriptionRetries(liveSessionSweep: {
            sweep.value = Task { await LiveSessionSpokenMarginSweep.fillMissingWords(files: worker, transcribe: transcribe) }
        })

        let first = await transcribe("interjections/phone-1.m4a")
        XCTAssertNil(first, "held: no words yet")
        XCTAssertEqual(reported.value, [.liveSessionMargin])
        for purpose in reported.value {
            ask.transcriptionHeld(purpose)
            retries.reported(purpose)
        }
        XCTAssertTrue(ask.isOwed(access: .notDetermined), "nothing recorded in the player, but a spoken Margin met the hold")
        XCTAssertEqual(ask.cardWording, .margins)
        let waiting = await worker.spokenWithoutWords().map(\.marginId)
        XCTAssertEqual(waiting, ["phone-1"])

        status.value = .authorized
        XCTAssertEqual(retries.settle(access: .authorized), 1, "one sweep covers the held Margins")
        let sweepTask = try XCTUnwrap(sweep.value, "Allow starts the sweep")
        let filled = await sweepTask.value
        XCTAssertEqual(filled, ["phone-1"])
        let session = await worker.session(id: sessionId)
        XCTAssertEqual(session?.margins.first { $0.id == "phone-1" }?.spokenTranscript, "my words")
        let stillWaiting = await worker.spokenWithoutWords()
        XCTAssertTrue(stillWaiting.isEmpty)
    }

    /// Director's Default taken on #4715 (2026-11-23): a listener whose first recording is a spoken note dictates a take.
    /// Its transcription meets the real gate's hold (as `SystemSpokenNoteTranscriber`, which the coordinator calls with
    /// `try`, keeping the take with no words); the report alone owes the card in the Margins words, and after Allow the
    /// spoken-note sweep fills the take's words in and brings the Library row's text up to date, with the recorder gone.
    @MainActor
    func testAHeldSpokenNoteIsOwedAndTranscribedAfterAllow() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "held-note-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1_000))
        let audio = "take-t1.m4a"
        try Data([0]).write(to: started.store.folderURL.appendingPathComponent(audio))
        try SpokenNoteIntake.addRecordedTake(audioFileName: audio, durationMs: 2_000, to: started.store,
                                             now: Date(timeIntervalSince1970: 1_000), takeId: "t1")

        let status = Box<SFSpeechRecognizerAuthorizationStatus>(.notDetermined)
        let reported = Box<[HeldTranscription]>([])
        let transcriber = GatedNoteTranscriber(status: status, reported: reported)
        let writer = RecordingItemWriter()

        // The take's transcription as the recorder makes it: it throws, and the take stays with no words.
        do {
            _ = try await transcriber.transcribe(fileAt: started.store.folderURL.appendingPathComponent(audio))
            XCTFail("held: the gate throws")
        } catch {
            XCTAssertTrue(HeldTranscription.isHold(error))
        }
        XCTAssertEqual(reported.value, [.spokenNote])
        XCTAssertFalse(started.store.load().takes[0].hasTranscript)

        // The app's sink (`SpeechAskController.holdReported`): the ask decides owed, the retries keep the sweep.
        var ask = SpeechRecognitionAsk(storedAnswer: nil)
        let sweep = Box<Task<[String], Never>?>(nil)
        let retries = HeldTranscriptionRetries(spokenNoteSweep: {
            sweep.value = Task {
                await SpokenNoteTranscriptSweep.fillMissingTranscripts(
                    in: support, transcriber: transcriber, itemWriter: writer, now: Date(timeIntervalSince1970: 2_000), liveNoteIds: [])
            }
        })
        for purpose in reported.value {
            ask.transcriptionHeld(purpose)
            retries.reported(purpose)
        }
        XCTAssertTrue(ask.isOwed(access: .notDetermined), "no spoken Margin anywhere, but the listener's spoken note met the hold")
        XCTAssertEqual(ask.cardWording, .margins)

        status.value = .authorized
        XCTAssertEqual(retries.settle(access: .authorized), 1, "one sweep covers the held takes")
        let sweepTask = try XCTUnwrap(sweep.value, "Allow starts the sweep")
        let filled = await sweepTask.value
        XCTAssertEqual(filled, [started.store.noteId])
        let take = try XCTUnwrap(started.store.load().takes.first)
        XCTAssertTrue(take.hasTranscript)
        XCTAssertEqual(started.store.load().text, "My words.")
        XCTAssertEqual(writer.written.value.last?.text, "My words.", "the Library row's text follows")
        XCTAssertEqual(reported.value, [.spokenNote], "no second hold after Allow")
    }

    private struct GatedNoteTranscriber: SpokenNoteTranscribing {
        let status: Box<SFSpeechRecognizerAuthorizationStatus>
        let reported: Box<[HeldTranscription]>

        func transcribe(fileAt url: URL) async throws -> [AlignedTranscriptSegment] {
            try await SpeechAuthorizationAsk.requireAuthorized(
                for: .spokenNote, current: status.value, mayAskSystem: false,
                reportHold: { [reported] purpose in reported.value.append(purpose) }) { .notDetermined }
            return [AlignedTranscriptSegment(id: "w0", text: "My", startMs: 0, endMs: 300),
                    AlignedTranscriptSegment(id: "w1", text: "words.", startMs: 400, endMs: 900)]
        }
    }

    private final class RecordingItemWriter: SpokenNoteItemWriting, @unchecked Sendable {
        let written = Box<[Item]>([])
        func write(_ item: Item, isFirstSave: Bool) throws { written.value.append(item) }
    }

    /// The compile-time guard, kept honest: the gate and every transcription client method that reaches it take a purpose
    /// with no default, and there is no second `requireAuthorized` without one. A purpose with a default would let a new
    /// caller meet the hold unnamed again.
    func testTheGateAndItsClientsHaveNoOverloadWithoutAPurpose() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources")
        let files = [
            "SessionKitAudio/SpeechAuthorizationAsk.swift", "SessionKitAudio/AudioAdapters.swift", "SessionKit/Protocols.swift",
        ]
        let gated = ["requireAuthorized", "transcribe", "transcribeAligned", "transcribeSourceAudio", "transcribeSourceAudioWindow",
                     "transcribeSourceAudioWindowWithEvidence"]
        var declarations: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOf: sources.appending(path: file), encoding: .utf8)
            XCTAssertFalse(text.contains("for purpose: HeldTranscription ="), "\(file): a purpose must have no default")
            for name in gated {
                var rest = Substring(text)
                while let found = rest.range(of: "func \(name)(") {
                    let after = rest[found.upperBound...]
                    let signature = after[..<(after.range(of: ") async")?.lowerBound ?? after.endIndex)]
                    declarations[name, default: 0] += 1
                    XCTAssertTrue(signature.contains("for purpose: HeldTranscription"), "\(file): func \(name) has no purpose")
                    rest = rest[found.upperBound...]
                }
            }
        }
        XCTAssertEqual(declarations["requireAuthorized"], 1, "one gate, no overload")
        for name in gated { XCTAssertNotNil(declarations[name], "func \(name) was not found: update this guard") }
    }
}
#endif
