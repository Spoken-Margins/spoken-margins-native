#if SM_LOCKED_MARGIN_SPIKE
import XCTest
import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// The Lock Screen record button of the locked-phone spike (#3086) starts and finishes a Margin through the app
/// model in the intent's own run, and leaves a report the owner's test reads from Diagnostics.
@MainActor
final class LockedMarginIntentTests: XCTestCase {
    private func makeModel() throws -> Gate1AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient(),
                                  databaseURLOverride: root.appendingPathComponent("library.sqlite"))
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        return model
    }

    func testBeginStartsTheMarginInTheIntentsRunAndFinishSavesIt() async throws {
        let model = try makeModel()
        try await model.runLockedMarginIntent(finish: false)
        XCTAssertTrue(model.snapshot.isRecording, "the Margin started before the intent returned")
        let begin = try XCTUnwrap(model.diagnostics["lastLockedMarginIntent"])
        XCTAssertTrue(begin.contains("action=begin"), begin)
        XCTAssertTrue(begin.contains("outcome=started"), begin)
        XCTAssertTrue(begin.contains("appState="), begin)
        XCTAssertTrue(begin.contains("protectedData="), begin)
        XCTAssertTrue(begin.contains("liveActivitiesBefore="), begin)

        try await model.runLockedMarginIntent(finish: true)
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.diagnostics["lastLockedMarginIntent"]?.contains("outcome=finished") == true,
                      model.diagnostics["lastLockedMarginIntent"] ?? "")
        model.endSession()
    }

    func testBeginWhileRecordingOnlyReports() async throws {
        let model = try makeModel()
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        try await model.runLockedMarginIntent(finish: false)
        XCTAssertTrue(model.snapshot.isRecording, "a second begin does not finish or restart the Margin")
        XCTAssertTrue(model.diagnostics["lastLockedMarginIntent"]?.contains("outcome=already_recording") == true,
                      model.diagnostics["lastLockedMarginIntent"] ?? "")
        model.dispatchGate2CompactCommand(.finishInterjection)
        model.endSession()
    }

    func testTheBridgeReachesTheModel() async throws {
        let model = try makeModel()
        let hostHandler = Gate2RecordMarginIntentBridge.handler
        addTeardownBlock { @MainActor in Gate2RecordMarginIntentBridge.handler = hostHandler }
        model.installLockedMarginIntentBridge()
        let handler = try XCTUnwrap(Gate2RecordMarginIntentBridge.handler)
        try await handler(false)
        XCTAssertTrue(model.snapshot.isRecording)
        try await handler(true)
        XCTAssertFalse(model.snapshot.isRecording)
        model.endSession()
    }
}
#endif
