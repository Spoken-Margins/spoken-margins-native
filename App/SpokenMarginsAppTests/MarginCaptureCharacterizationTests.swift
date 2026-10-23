import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The Margin capture state as the model shows it (#993, T7 part 2). These tests use only the model's own API, so
/// they pass on the code before the capture state moved out of `Gate1AppModel` and must pass unchanged after.
/// They pin what the extraction could silently change: when observers are told, which request answers are
/// ignored as stale, what a compact control does after the listener cancelled, and which code runs while the
/// recorder starts. Each test names the line of the rule it guards.
@MainActor
final class MarginCaptureCharacterizationTests: XCTestCase {
    private var voicePreferences = VoicePreferencesSnapshot.capture()

    /// Choosing a voice (`declineCurrentTerms()`) writes the app's shared preferences; without a choice a first
    /// run holds `startItem` behind the Terms sheet and nothing can record. The suite puts them back after.
    override func setUp() {
        super.setUp()
        voicePreferences = VoicePreferencesSnapshot.capture()
    }

    override func tearDown() {
        voicePreferences.restore()
        super.tearDown()
    }

    /// Observers are told a change is coming before it lands, once per write, in the order the model wrote them.
    /// Cancelling a pending request writes the primer, the request flag and the presentation context.
    func testCancellingAPendingRequestAnnouncesEachWriteBeforeItHappens() async throws {
        let gate = QueuedPermissionGate()
        let model = makeModel(gate: gate)
        model.beginInterjection()
        try await waitFor("the request to ask") { gate.requests == 1 }
        XCTAssertTrue(model.isRequestingRecordingPermission)
        XCTAssertNotNil(model.recordingPresentationContext)

        var seen: [CaptureNotice] = []
        let observation = model.objectWillChange.sink { seen.append(CaptureNotice(model)) }
        defer { observation.cancel() }
        model.cancelInterjection()

        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertNil(model.recordingPresentationContext)
        XCTAssertEqual(seen, [
            CaptureNotice(requesting: true, hasContext: true), // the primer, written first
            CaptureNotice(requesting: true, hasContext: true), // the request flag, about to clear
            CaptureNotice(requesting: false, hasContext: true), // the context, about to clear
        ])
    }

    /// Asking to finish writes the finishing flag and then the restart shield, and nothing else, before the
    /// acknowledgement wait.
    func testAskingToFinishAnnouncesTheFlagAndThenTheShield() async throws {
        let model = makeModel()
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)

        var finishing: [Bool] = []
        let finishObservation = model.objectWillChange.sink { finishing.append(model.isFinishingInterjection) }
        model.requestFinishInterjection()
        finishObservation.cancel()
        XCTAssertEqual(finishing, [false, true], "the flag, then the shield")
        try await waitFor("the finish to land") { !model.isFinishingInterjection }
    }

    func testADraftEditIsOneNoticeAndNoneWithoutADraft() {
        let model = makeModel()
        model.beginWrittenMargin()
        XCTAssertNotNil(model.writtenMarginDraft)
        var edits = 0
        let editObservation = model.objectWillChange.sink { edits += 1 }
        defer { editObservation.cancel() }
        model.updateWrittenMarginText("a")
        XCTAssertEqual(edits, 1, "one notice for an edit")
        XCTAssertEqual(model.writtenMarginDraft?.text, "a")
        model.cancelWrittenMargin()
        XCTAssertNil(model.writtenMarginDraft)
        edits = 0
        model.updateWrittenMarginText("b")
        XCTAssertEqual(edits, 0, "no draft, nothing written, nothing announced")
        XCTAssertNil(model.writtenMarginDraft)
    }

    /// A late denial of an older request must not clear a newer request that is still waiting (the fence in
    /// `requestMicrophoneThenRecord`).
    func testALateDenialForACancelledRequestChangesNothing() async throws {
        let gate = QueuedPermissionGate()
        let model = makeModel(gate: gate)
        model.beginInterjection()
        try await waitFor("request A to ask") { gate.requests == 1 }
        model.cancelInterjection()
        model.beginInterjection()
        try await waitFor("request B to ask") { gate.requests == 2 }

        gate.answer(0, granted: false)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(model.isRequestingRecordingPermission, "B is still waiting")
        XCTAssertNotNil(model.recordingPresentationContext)
        XCTAssertFalse(model.recordingPermissionDenied)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.snapshot.isRecording)

        gate.answer(1, granted: true)
        try await waitFor("B to record") { model.snapshot.isRecording }
        XCTAssertFalse(model.isRequestingRecordingPermission)
        model.cancelInterjection()
    }

    /// A late grant for an older request must not start a recording for it (the fence in
    /// `requestMicrophoneThenRecord`), and must not disturb the newer request.
    func testALateGrantForACancelledRequestStartsNothing() async throws {
        let gate = QueuedPermissionGate()
        let recorder = CallbackRecordingClient()
        let model = makeModel(gate: gate, recorder: recorder)
        model.beginInterjection()
        try await waitFor("request A to ask") { gate.requests == 1 }
        model.cancelInterjection()
        model.beginInterjection()
        try await waitFor("request B to ask") { gate.requests == 2 }

        gate.answer(0, granted: true)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(recorder.beginCount, 0, "the stale grant started no recording")
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.isRequestingRecordingPermission, "B is still waiting")

        gate.answer(1, granted: true)
        try await waitFor("B to record") { model.snapshot.isRecording }
        XCTAssertEqual(recorder.beginCount, 1)
        model.cancelInterjection()
    }

    /// #2126: a grant from a compact control (Live Activity, widget, headphones) that arrives after the listener
    /// cancelled in the app starts nothing. The compact request carries a token through the prompt, as the in-app
    /// request carries its ID. This was pinned as today's behaviour, with the note that fencing it needed its own issue.
    func testACompactControlGrantAfterTheListenerCancelledStartsNothing() async throws {
        let gate = QueuedPermissionGate()
        let recorder = CallbackRecordingClient()
        let model = makeModel(gate: gate, recorder: recorder, status: .denied)
        model.dispatchGate2CompactCommand(.beginInterjection, origin: "live_activity")
        try await waitFor("the compact control to ask") { gate.requests == 1 }
        XCTAssertTrue(model.isRequestingRecordingPermission)

        model.cancelInterjection()
        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertFalse(model.snapshot.isRecording)

        gate.answer(0, granted: true)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(recorder.beginCount, 0, "the late grant started no recording")
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertNil(model.recordingPresentationContext)
    }

    /// #2126: without a Cancel, the compact control's grant still records.
    func testACompactControlGrantWithNoCancelStillRecords() async throws {
        let gate = QueuedPermissionGate()
        let model = makeModel(gate: gate, status: .denied)
        model.dispatchGate2CompactCommand(.beginInterjection, origin: "live_activity")
        try await waitFor("the compact control to ask") { gate.requests == 1 }

        gate.answer(0, granted: true)
        try await waitFor("the grant to record") { model.snapshot.isRecording }

        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertNotNil(model.recordingPresentationContext)
        model.dispatchGate2CompactCommand(.cancelInterjection)
    }

    /// A new request clears an earlier denial at once, before the answer comes back.
    func testANewRequestClearsAnEarlierDenialAtOnce() async throws {
        let gate = QueuedPermissionGate()
        let model = makeModel(gate: gate)
        model.beginInterjection()
        try await waitFor("the first request to ask") { gate.requests == 1 }
        gate.answer(0, granted: false)
        try await waitFor("the denial to show") { model.recordingPermissionDenied }
        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertNil(model.recordingPresentationContext)

        model.beginInterjection()

        XCTAssertFalse(model.recordingPermissionDenied, "cleared by the tap, not by the answer")
        XCTAssertTrue(model.isRequestingRecordingPermission)
        try await waitFor("the second request to ask") { gate.requests == 2 }
        gate.answer(1, granted: false)
        try await waitFor("the second denial to show") { model.recordingPermissionDenied }
    }

    /// While the recorder starts, the request is still pending and the screen still locked: a command drained from
    /// the widget queue by `snapshot.didSet` at that moment sees a request in progress (the `defer` in
    /// `startInterjectionRecording` clears it only after the engine call).
    func testTheRequestIsStillPendingWhileTheRecorderStarts() async throws {
        let recorder = CallbackRecordingClient()
        let model = makeModel(recorder: recorder)
        var seen: [CaptureStart] = []
        recorder.onBegin = {
            MainActor.assumeIsolated {
                seen.append(CaptureStart(
                    requesting: model.isRequestingRecordingPermission,
                    locked: model.recordingNavigationIsLocked,
                    hasContext: model.recordingPresentationContext != nil
                ))
            }
        }

        model.beginInterjection()

        XCTAssertEqual(seen, [CaptureStart(requesting: true, locked: true, hasContext: true)])
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertFalse(model.isRequestingRecordingPermission, "cleared after the engine call returns")
        model.cancelInterjection()
    }

    /// Only a requested finish engages the restart shield. Finishing straight away does not.
    func testOnlyARequestedFinishEngagesTheRestartShield() async throws {
        let model = makeModel()
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        model.finishInterjection()
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertFalse(model.isMarginCaptureCoolingDown, "a direct finish leaves the shield open")

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        model.requestFinishInterjection()
        model.requestFinishInterjection()
        try await waitFor("the finish to land") { !model.isFinishingInterjection }
        XCTAssertTrue(model.isMarginCaptureCoolingDown)
        model.beginWrittenMargin()
        XCTAssertNil(model.writtenMarginDraft, "the pencil waits for the shield too")
    }

    private func makeModel(
        gate: QueuedPermissionGate? = nil,
        recorder: RecordingClient = NoopRecordingClient(),
        status: PermissionPromptStatus? = nil
    ) -> Gate1AppModel {
        let model: Gate1AppModel
        switch (gate, status) {
        case let (gate?, status?):
            model = Gate1AppModel(
                audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder,
                microphonePermissionRequest: { await gate.request() }, microphonePermissionStatus: { status }
            )
        case let (gate?, nil):
            model = Gate1AppModel(
                audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder,
                microphonePermissionRequest: { await gate.request() }
            )
        default:
            model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: recorder)
        }
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()
        return model
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// What an observer reads at one notice.
private struct CaptureNotice: Equatable {
    let requesting: Bool
    let hasContext: Bool

    init(requesting: Bool, hasContext: Bool) {
        self.requesting = requesting
        self.hasContext = hasContext
    }

    @MainActor init(_ model: Gate1AppModel) {
        self.init(requesting: model.isRequestingRecordingPermission, hasContext: model.recordingPresentationContext != nil)
    }
}

private struct CaptureStart: Equatable {
    let requesting: Bool
    let locked: Bool
    let hasContext: Bool
}

/// Keeps every permission request open until the test answers it, in the order they were asked. The model's own
/// test gate holds one continuation, which would drop the first when two requests overlap.
@MainActor
private final class QueuedPermissionGate {
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private(set) var requests = 0

    func request() async -> Bool {
        requests += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func answer(_ index: Int, granted: Bool) {
        continuations[index].resume(returning: granted)
    }
}

/// A recorder that counts starts and lets a test look at the model from inside the engine's call.
private final class CallbackRecordingClient: RecordingClient, @unchecked Sendable {
    var onBegin: (() -> Void)?
    private(set) var beginCount = 0

    func beginRecording() throws {
        beginCount += 1
        onBegin?()
    }

    func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/generated.m4a" }
    func cancelRecording() throws {}
}
