import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #1669: Write instead while a Margin is recording. The engine's rules (the place, the reply link, the recording's
/// file) are host-tested in SessionKit; these tests pin what the model does with them: the recording screen gives
/// way to the written Margin screen, and the words the listener types are saved as a written Margin.
@MainActor
final class SwitchRecordingToWrittenMarginAppTests: XCTestCase {
    private var voicePreferences = VoicePreferencesSnapshot.capture()

    /// Choosing a voice (`declineCurrentTerms()`) writes the app's shared preferences; the suite puts them back after.
    override func setUp() {
        super.setUp()
        voicePreferences = VoicePreferencesSnapshot.capture()
    }

    override func tearDown() {
        voicePreferences.restore()
        super.tearDown()
    }

    private func makeRecordingModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()
        model.beginInterjection()
        return model
    }

    /// What the library holds for the session, read straight from its store.
    private func savedMargins(_ model: Gate1AppModel) throws -> [Interjection] {
        try XCTUnwrap(model.store).loadInterjections(sessionId: try XCTUnwrap(model.snapshot.sessionId))
            .filter { $0.status == "active" }
    }

    func testSwitchingLeavesTheRecordingScreenForTheWrittenOne() throws {
        let model = makeRecordingModel()
        XCTAssertTrue(model.snapshot.isRecording)
        let itemId = try XCTUnwrap(model.snapshot.itemId)

        model.switchRecordingToWrittenMargin()

        XCTAssertFalse(model.snapshot.isRecording, "the recording is gone")
        XCTAssertNil(model.recordingPresentationContext)
        XCTAssertFalse(model.isRequestingRecordingPermission)
        let draft = try XCTUnwrap(model.writtenMarginDraft, "and the written Margin is open")
        XCTAssertEqual(draft.lockedItemID, itemId)
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(model.recordingNavigationIsLocked, "the listener stays on the capture screen until they save or cancel")
    }

    func testTheWordsTypedAfterSwitchingAreSavedAsAWrittenMargin() throws {
        let model = makeRecordingModel()
        model.switchRecordingToWrittenMargin()
        model.updateWrittenMarginText("Better in writing.")

        model.saveWrittenMargin(text: "Better in writing.")

        XCTAssertNil(model.writtenMarginDraft)
        let saved = try savedMargins(model)
        XCTAssertEqual(saved.map(\.displayText), ["Better in writing."])
        XCTAssertEqual(saved.first?.captureKind, .written)
        XCTAssertNil(saved.first?.audioPath, "the discarded recording left no voice behind")
    }

    func testCancellingTheWritingAfterSwitchingSavesNothing() throws {
        let model = makeRecordingModel()
        model.switchRecordingToWrittenMargin()

        model.cancelWrittenMargin()

        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(try savedMargins(model).isEmpty)
    }

    func testSwitchingWithoutARecordingDoesNothing() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()

        model.switchRecordingToWrittenMargin()

        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertFalse(model.snapshot.isRecording)
    }
}
