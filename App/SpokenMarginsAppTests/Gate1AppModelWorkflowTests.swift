import XCTest
@testable import SpokenMarginsApp

@MainActor
final class Gate1AppModelWorkflowTests: XCTestCase {
    func testManualImportClearsEntryFieldsAfterSuccessfulCreate() {
        let model = Gate1AppModel()
        model.resetAndSeed()
        model.importTitle = "Scratch Item"
        model.importText = "This is pasted text. It should not remain in the import form."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.importTitle, "")
        XCTAssertEqual(model.importText, "")
        XCTAssertEqual(model.selectedItem.title, "Scratch Item")
    }

    func testResumeCompletedSessionAfterExportRestartsSourcePlayback() throws {
        let model = Gate1AppModel()
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
