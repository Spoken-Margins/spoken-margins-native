import XCTest
import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Gate1AppModelWorkflowTests: XCTestCase {
    func testManualImportClearsEntryFieldsAfterSuccessfulCreate() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Scratch Item"
        model.importText = "This is pasted text. It should not remain in the import form."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.importTitle, "")
        XCTAssertEqual(model.importText, "")
        XCTAssertEqual(model.selectedItem.title, "Scratch Item")
    }

    func testTextImportStartsLiveSpeechWhenPreparedRenderingIsUnavailable() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            forcePreparedTextGate: true
        )
        model.resetAndSeed()
        model.importTitle = "Prepared First"
        model.importText = "This text should start immediately while generated audio renders in the background."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertNil(model.pendingPreparedTextStartItemId)
        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.preparedTextAudioStatus, "live_fallback")
        XCTAssertFalse(model.canPlayLiveSpeechInstead)
    }

    func testResumeCompletedSessionAfterExportRestartsSourcePlayback() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Short Item"
        model.importText = "One sentence only."
        model.importTextItem()
        model.skipUnit = "section"
        model.skipForward()
        model.openExport()

        let completedSession = try XCTUnwrap(model.selectedItem.sessions.last)
        model.resumeSession(completedSession)

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, "item_text_tts")
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 0)
    }
}
