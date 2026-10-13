import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The capture coordinator on its own (#993). The model-level behaviour is in `MarginCaptureCharacterizationTests`
/// and the existing workflow tests; these pin the rules the coordinator applies itself, each of which fails when
/// the line that implements it is removed or changed.
@MainActor
final class MarginCaptureCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    /// Every write the coordinator makes reaches the model's observers before it lands, through the one relay.
    /// (Fails if the relay is removed, made asynchronous, or a write bypasses it.)
    func testEveryCoordinatorWriteReachesTheModelBeforeItHappens() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        var requestingAtEachNotice: [Bool] = []
        var finishingAtEachNotice: [Bool] = []
        var contextAtEachNotice: [Bool] = []
        let observation = model.objectWillChange.sink {
            requestingAtEachNotice.append(model.isRequestingRecordingPermission)
            finishingAtEachNotice.append(model.isFinishingInterjection)
            contextAtEachNotice.append(model.recordingPresentationContext != nil)
        }
        defer { observation.cancel() }

        model.marginCapture.beginCompactRequest()
        XCTAssertEqual(requestingAtEachNotice, [false], "told before the request flag changed")
        XCTAssertTrue(model.isRequestingRecordingPermission)

        XCTAssertTrue(model.marginCapture.requestFinish())
        XCTAssertEqual(finishingAtEachNotice.suffix(2), [false, true], "the flag, then the shield")
        XCTAssertTrue(model.isFinishingInterjection)

        model.marginCapture.setPresentationContext(context())
        XCTAssertEqual(contextAtEachNotice.last, false, "told before the context appeared")
        XCTAssertNotNil(model.recordingPresentationContext)
    }

    /// An answer for a request that is not the current one changes nothing; a denial ends the current one; a grant
    /// writes nothing and leaves the request for `releaseStart`.
    func testAnAnswerForAnOlderRequestIsStale() {
        let capture = MarginCaptureCoordinator()
        let older = capture.beginVoiceRequest()
        let current = capture.beginVoiceRequest()
        capture.setPresentationContext(context())
        var notices = 0
        let observation = capture.objectWillChange.sink { notices += 1 }
        defer { observation.cancel() }

        XCTAssertEqual(capture.resolvePermission(for: older, granted: false), .stale)
        XCTAssertEqual(capture.resolvePermission(for: older, granted: true), .stale)
        XCTAssertFalse(capture.claimStart(for: older))
        XCTAssertEqual(notices, 0, "a stale answer writes nothing")
        XCTAssertTrue(capture.isRequestingPermission)
        XCTAssertNotNil(capture.presentationContext)
        XCTAssertFalse(capture.permissionDenied)

        XCTAssertEqual(capture.resolvePermission(for: current, granted: true), .granted)
        XCTAssertEqual(notices, 0, "a grant writes nothing")
        XCTAssertTrue(capture.claimStart(for: current))

        XCTAssertEqual(capture.resolvePermission(for: current, granted: false), .denied)
        XCTAssertEqual(notices, 3, "request flag, context, denial")
        XCTAssertFalse(capture.isRequestingPermission)
        XCTAssertNil(capture.presentationContext)
        XCTAssertTrue(capture.permissionDenied)
        XCTAssertFalse(capture.claimStart(for: current), "the denial ended the request")
    }

    /// Continue on the primer goes on once, and only for the request that is still current.
    func testContinueOnThePrimerIsOneShotAndMatchesTheRequest() {
        let capture = MarginCaptureCoordinator()
        let id = capture.beginVoiceRequest()
        XCTAssertTrue(capture.holdForPrimer(captureID: id, status: .undetermined))
        XCTAssertTrue(capture.primer.isShowing)
        XCTAssertEqual(capture.continuePrimer(), id)
        XCTAssertFalse(capture.primer.isShowing)
        XCTAssertNil(capture.continuePrimer(), "a second Continue tap does nothing")

        let moved = capture.beginVoiceRequest()
        XCTAssertTrue(capture.holdForPrimer(captureID: id, status: .undetermined), "the primer holds the older request")
        XCTAssertNil(capture.continuePrimer(), "the request has moved on")
        XCTAssertFalse(capture.primer.isShowing, "and the primer still clears")
        XCTAssertTrue(capture.claimStart(for: moved))

        XCTAssertFalse(capture.holdForPrimer(captureID: moved, status: .granted), "an answered microphone shows no primer")
        XCTAssertFalse(capture.primer.isShowing)
    }

    /// One finish at a time, and the shield follows the screen: closed while saving, closed until the listening
    /// screen has stayed a second, closed for four seconds when it never reports, open at once when the save
    /// left the recording running.
    func testFinishCannotBeRequestedTwiceAndTheShieldFollowsTheScreen() {
        let capture = MarginCaptureCoordinator()
        XCTAssertFalse(capture.isCoolingDown(at: now))
        XCTAssertTrue(capture.requestFinish())
        XCTAssertFalse(capture.requestFinish(), "a second request while one is under way is ignored")
        XCTAssertTrue(capture.isFinishing)
        XCTAssertTrue(capture.isCoolingDown(at: now), "closed while the save is under way")

        capture.finalizeFinish(at: now, stillRecording: false)
        XCTAssertFalse(capture.isFinishing)
        XCTAssertTrue(capture.isCoolingDown(at: now), "closed until the screen has appeared")
        capture.screenAppeared(at: now.addingTimeInterval(2))
        XCTAssertTrue(capture.isCoolingDown(at: now.addingTimeInterval(2.99)))
        XCTAssertFalse(capture.isCoolingDown(at: now.addingTimeInterval(3.01)))

        let silent = MarginCaptureCoordinator()
        XCTAssertTrue(silent.requestFinish())
        silent.finalizeFinish(at: now, stillRecording: false)
        XCTAssertTrue(silent.isCoolingDown(at: now.addingTimeInterval(3.99)))
        XCTAssertFalse(silent.isCoolingDown(at: now.addingTimeInterval(4.01)), "the fallback when no screen is reported")

        let kept = MarginCaptureCoordinator()
        XCTAssertTrue(kept.requestFinish())
        kept.finalizeFinish(at: now, stillRecording: true)
        XCTAssertFalse(kept.isCoolingDown(at: now), "a save that left the recording running opens the shield")
    }

    /// Abandoning a request clears the primer, the request and the context, and tells observers in that order;
    /// the compact writes touch only the request flag.
    func testAbandonAndTheCompactWritesKeepTheirOldOrderAndReach() {
        let capture = MarginCaptureCoordinator()
        let id = capture.beginVoiceRequest()
        capture.setPresentationContext(context())
        XCTAssertTrue(capture.holdForPrimer(captureID: id, status: .undetermined))
        var seen: [AbandonNotice] = []
        let observation = capture.objectWillChange.sink { seen.append(AbandonNotice(capture)) }
        defer { observation.cancel() }

        capture.abandonVoiceRequest()

        XCTAssertEqual(seen, [
            AbandonNotice(primerShowing: true, requesting: true, hasContext: true),
            AbandonNotice(primerShowing: false, requesting: true, hasContext: true),
            AbandonNotice(primerShowing: false, requesting: false, hasContext: true),
        ])
        XCTAssertFalse(capture.claimStart(for: id), "the request is gone")
        XCTAssertFalse(capture.permissionDenied, "abandoning does not forget or set a denial")

        seen.removeAll()
        capture.beginCompactRequest()
        capture.endCompactRequest()
        XCTAssertEqual(seen.count, 2)
        XCTAssertNil(capture.pendingVoiceRequestID, "a compact request has no ID")
    }

    /// Closing the draft is a write, so it announces even when there is no draft to close.
    func testClosingADraftAlwaysAnnounces() {
        let capture = MarginCaptureCoordinator()
        var notices = 0
        let observation = capture.objectWillChange.sink { notices += 1 }
        defer { observation.cancel() }
        capture.closeDraft()
        XCTAssertNil(capture.writtenDraft)
        XCTAssertEqual(notices, 1)
    }

    /// Equal-value writes still announce: nothing compares first.
    func testClearingTheContextAlwaysAnnounces() {
        let capture = MarginCaptureCoordinator()
        var notices = 0
        let observation = capture.objectWillChange.sink { notices += 1 }
        defer { observation.cancel() }
        capture.clearPresentationContext()
        capture.clearPresentationContext()
        capture.clearPermissionDenied()
        capture.endCompactRequest()
        XCTAssertEqual(notices, 4)
    }

    private func context() -> RecordingPresentationContext {
        RecordingPresentationContext(itemTitle: "Item", locationTitle: "Here", progressPercent: 0, startedAt: now)
    }
}

private struct AbandonNotice: Equatable {
    let primerShowing: Bool
    let requesting: Bool
    let hasContext: Bool

    init(primerShowing: Bool, requesting: Bool, hasContext: Bool) {
        self.primerShowing = primerShowing
        self.requesting = requesting
        self.hasContext = hasContext
    }

    @MainActor init(_ capture: MarginCaptureCoordinator) {
        self.init(primerShowing: capture.primer.isShowing, requesting: capture.isRequestingPermission, hasContext: capture.presentationContext != nil)
    }
}
