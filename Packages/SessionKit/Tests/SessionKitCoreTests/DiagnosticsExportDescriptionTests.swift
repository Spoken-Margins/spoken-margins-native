import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #5126: Settings › Share Diagnostics and the Export Diagnostics Shortcuts action show one description of the file.
/// It must say what the file really holds: a title inside an item id and a link go into a fixture export, neither may
/// come out, and the text must say so rather than claim the file carries the titles and links of the Library.
final class DiagnosticsExportDescriptionTests: XCTestCase {
    func testTheContentsDescriptionMatchesWhatTheExportCarries() throws {
        let live = [
            "lastImport": "item-browser-zanzibar-holiday-plans-https-example-com-a",
            "podcastDownload:Zanzibar Holiday Plans": "queued",
            "lastSharedArticleAcquisition": "fetched:https://example.com/zanzibar-holiday-plans",
        ]
        let fixed = DiagnosticsExport.Fixed(
            developerBuild: "0.1 (37) abc1234", developerRecording: nil, playbackEvents: nil,
            exportedAt: Date(timeIntervalSince1970: 1_791_466_622),
            playbackStatus: "idle", sessionPhase: "idle", targetType: nil, pendingAIJobs: 0)
        let text = try DiagnosticsExport.jsonText(DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed))
        XCTAssertFalse(text.lowercased().contains("zanzibar"), text)
        XCTAssertFalse(text.contains("example.com"), text)
        XCTAssertTrue(text.contains(DiagnosticsExport.schemaVersion), text)

        let description = DiagnosticsExportFile.contentsDescription
        XCTAssertFalse(description.contains("titles and links"), description)
        XCTAssertTrue(description.contains("placeholders"), description)
        XCTAssertTrue(description.contains("not by their titles"), description)
    }

    /// The Shortcuts action's description is a literal (App Intents reads it at build time), so it is checked here
    /// against the shared text, and the Settings footer and the action must both go through the shared pieces: the one
    /// description and the one off-main write, never a second copy of the export (#5126).
    func testTheShortcutsActionAndSettingsShareOneDescriptionAndOneExportPath() throws {
        let intent = try TestInputs.text(.appSources, "ExportDiagnosticsShortcutIntent.swift")
        XCTAssertTrue(intent.contains(DiagnosticsExportFile.contentsDescription), "the action's description must carry the shared text word for word")
        XCTAssertTrue(intent.contains("static let openAppWhenRun = false"))
        let intentCode = try TestInputs.code(.appSources, "ExportDiagnosticsShortcutIntent.swift")
        XCTAssertTrue(intentCode.contains("writeDiagnosticsExportFileOffMain()"))
        XCTAssertFalse(intentCode.contains("DiagnosticsExport.entries"), "no second copy of the redaction")

        let settings = try TestInputs.code(.appSources, "SettingsScreen.swift")
        XCTAssertTrue(settings.contains("DiagnosticsExportFile.contentsDescription"))
        XCTAssertFalse(settings.contains("titles and links"))
    }
}
