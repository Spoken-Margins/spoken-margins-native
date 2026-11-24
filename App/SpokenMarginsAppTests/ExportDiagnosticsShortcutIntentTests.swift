import AppIntents
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #5126: the Export Diagnostics action returns the same safe file as Settings › Share Diagnostics, never an empty one,
/// and leaves what is playing alone.
@MainActor
final class ExportDiagnosticsShortcutIntentTests: XCTestCase {
    func testTheActionSaysWhyWhenTheAppIsUnavailable() async {
        do {
            _ = try await ExportDiagnosticsShortcutAction.file(model: nil)
            XCTFail("a missing app model must not hand on an empty file")
        } catch {
            XCTAssertEqual(error as? ExportDiagnosticsShortcutError, .appUnavailable)
        }
    }

    func testTheActionReturnsTheSafeDiagnosticsFileAndLeavesPlaybackAlone() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        let statusBefore = model.snapshot.status
        let sessionBefore = model.snapshot.sessionId
        model.diagnostics["runtimeProfile"] = "test-profile"
        model.diagnostics["lastBrowserTextSource"] = "private source content"
        model.diagnostics["lastSharedArticleAcquisition"] = "fetched:https://example.com/zanzibar-holiday-plans"

        let file = try await ExportDiagnosticsShortcutAction.file(model: model)

        XCTAssertEqual(file.type, .json)
        XCTAssertTrue(file.filename.hasPrefix("Spoken Margins diagnostics "), file.filename)
        XCTAssertTrue(file.filename.hasSuffix(".json"), file.filename)
        let text = String(decoding: file.data, as: UTF8.self)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: file.data) as? [String: String])
        XCTAssertEqual(payload["schemaVersion"], DiagnosticsExport.schemaVersion)
        XCTAssertEqual(payload["runtimeProfile"], "test-profile")
        XCTAssertNil(payload["lastBrowserTextSource"])
        XCTAssertFalse(text.contains("private source content"))
        XCTAssertFalse(text.contains("example.com"))
        XCTAssertEqual(model.snapshot.status, statusBefore, "the action must not pause or stop what is playing")
        XCTAssertEqual(model.snapshot.sessionId, sessionBefore)
        XCTAssertNotEqual(model.feedbackEvent?.kind, .error)
    }
}
