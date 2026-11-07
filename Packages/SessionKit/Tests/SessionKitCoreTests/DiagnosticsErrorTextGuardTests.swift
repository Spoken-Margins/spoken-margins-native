import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// Error text must not reach the diagnostics export (#3548). A system error's message can name a file or folder
/// the listener chose, and `String(describing:)` of an enum prints its payload. The app writes errors into the
/// export through `SafeErrorText.describe`, which keeps only the domain, the code and an enum's case name.
///
/// This reads the app's real sources, the way `DiagnosticsExportPrivacyTests` reads the real diagnostics keys, and
/// fails when a line writes `localizedDescription`, `errorDescription` or `String(describing: error)` anywhere but
/// the short list below of places the listener sees the text. A new line fails here until it uses `SafeErrorText`,
/// or is added to the list with its reason, which a reviewer reads.
final class DiagnosticsErrorTextGuardTests: XCTestCase {
    /// The error variables the app names in a `catch`, and the `Error` parameters that carry one.
    private static let errorNames = #"(?:error|err|failure|underlying|nsError|readFailure|parserError|e)"#

    /// A line that turns an error into free text.
    static func unsafeErrorText(in line: String) -> Bool {
        let patterns = [
            #"\.localizedDescription\b"#,
            #"\.errorDescription\b"#,
            #"String\((?:describing|reflecting): *(?:[A-Za-z_]+\.)*\#(errorNames)\)"#,
            #"\\\(\#(errorNames)\)"#,
        ]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    /// Lines in the app where the listener is shown the text, or it is stored for a screen, never put in the export.
    /// Each entry is a file name and a fragment of the line, with why it is not export text.
    private static let shownToTheListener: [(file: String, fragment: String, why: String)] = [
        ("ReadLaterModel.swift", "(error as? EditionError)?.localizedDescription", "the Read Later screen's own message"),
        ("SharedMarginsImportMessage.swift", "?? error.localizedDescription", "the listener's import message, cut to plain words after"),
        ("Gate1AppModel+RemoteProvider.swift", "LocalSummaryFailurePresentation(errorDescription: error.localizedDescription)", "the summary failure card"),
        ("Gate1AppModel+RemoteProvider.swift", "String(describing: error),", "the provider failure record, kept off the export under recentFailure"),
        ("Gate1AppModel+FileImport.swift", "rawFailures.append(", "the raw bug-report text, which lands under recentFailure and never leaves"),
        ("Gate1AppModel+FileImport.swift", "result.rawFailures.append(", "the raw bug-report text, which lands under recentFailure and never leaves"),
        ("PodcastDownloadCoordinator.swift", "reason: error.localizedDescription", "the download card's reason; the export carries only its token"),
        ("Gate1AppModel+LibrarySeeding.swift", "libraryAccessError =", "the library-access alert"),
        ("Gate1AppModel+Feedback.swift", "rawMessage = String(describing: error)", "the bug report's raw text, which lands under recentFailure and never leaves"),
        ("Gate1AppModel+ImportInbox.swift", "quarantine(payloadID: payloadID, reason: error.localizedDescription)", "the import inbox row's reason"),
        ("Gate1AppModel+SourceWindowContext.swift", "let failure = String(describing: error)", "the Margin's transcription wording; the export line uses `diagnostic`"),
        ("Gate1AppModel+ShareDrafts.swift", "Pause analysis was unavailable (", "text on the share screen"),
        ("LocalFoundationModels.swift", "String(reflecting: error).lowercased()", "decides which failure it is; not stored"),
        ("Gate1AppModel+MarginVoiceHold.swift", "String(describing: move)", "a hand-over case name, not an error"),
        ("Gate1AppModel.swift", "String(describing: newValue)", "a navigation case name, not an error"),
        ("Gate2CompactControlController.swift", "live_speech_audio_session_failed:\\(failure)", "`failure` holds SafeErrorText.describe output by then"),
        ("QuickAccessFolderState.swift", "scan.errorDescription", "reads a property that already holds SafeErrorText output"),
        ("ReadwiseHighlightSync.swift", "ReadwiseHighlightError.tokenRejected.errorDescription", "the Readwise status line the listener reads"),
        ("Gate1AppModel+Feedback.swift", "localized.errorDescription", "the bug report's raw text, which lands under recentFailure and never leaves"),
    ]

    /// SessionKit lines shown to the listener or used for a screen that reach `unsafeErrorText` and are near a word that
    /// looks like a diagnostics write.
    private static let sessionKitShownToTheListener: [(file: String, fragment: String, why: String)] = [
        ("SessionEngine.swift", "snapshot.lastFailure = \"transcription_failed:", "lastFailure is a blocked export key (keyMayContainUserContent)"),
        ("SessionEngine.swift", "snapshot.lastFailure = \"\\(publisherAudio", "lastFailure is a blocked export key (keyMayContainUserContent)"),
        ("OPML.swift", "?? error.localizedDescription", "the import result's reason the listener reads; the app passes `describe`"),
    ]

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return (walker.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    private func unsafeLines(in files: [URL], allowed: [(file: String, fragment: String, why: String)], needing: ((String) -> Bool)? = nil) throws -> [String] {
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"), Self.unsafeErrorText(in: line) else { continue }
                if let needing, !needing(line) { continue }
                if allowed.contains(where: { $0.file == file.lastPathComponent && line.contains($0.fragment) }) { continue }
                found.append("\(file.lastPathComponent):\(index + 1): \(trimmed)")
            }
        }
        return found
    }

    func testNoAppLineWritesErrorTextExceptWhereTheListenerSeesIt() throws {
        let inputs: [TestInputs.Input] = [.appSources, .appSharedSources, .appGate2Shared, .appBrowserTextExtension, .appShareExtension, .appGate2Widget]
        var files: [URL] = []
        for input in inputs { files += swiftFiles(under: try TestInputs.directory(input)) }
        XCTAssertGreaterThan(files.count, 100, "the scan found too few files: has the app moved?")
        let found = try unsafeLines(in: files, allowed: Self.shownToTheListener)
        XCTAssertEqual(found, [], "Error text reaches app code that can write the diagnostics export. Use SafeErrorText.describe(error), or list the line in shownToTheListener with why it is never exported.")
        for entry in Self.shownToTheListener {
            let present = try files.contains { try String(contentsOf: $0, encoding: .utf8).contains(entry.fragment) && $0.lastPathComponent == entry.file }
            XCTAssertTrue(present, "\(entry.file) no longer holds \u{201C}\(entry.fragment)\u{201D}; remove the stale entry (\(entry.why))")
        }
    }

    /// SessionKit builds some export text itself (failure details, event reasons). Its lines that name a diagnostic, a reason or a
    /// record, and write error text, fail the same way.
    func testNoSessionKitDiagnosticLineWritesErrorText() throws {
        let sources = TestInputs.packageRoot.appending(path: "Sources")
        let looksLikeAnExportWrite: (String) -> Bool = { line in
            ["diagnostic", "reason:", "record(", "Failure =", "failure:", "lastWriteError", "errorDescription:"].contains { line.contains($0) }
        }
        let found = try unsafeLines(in: swiftFiles(under: sources), allowed: Self.sessionKitShownToTheListener, needing: looksLikeAnExportWrite)
        XCTAssertEqual(found, [])
    }

    func testTheScannerSeesTheShapesTheAppUses() {
        let unsafe = [
            #"diagnostics["localAudioSkim:x"] = "failed:\(error.localizedDescription)""#,
            #"diagnostics["homeLibraryRefreshError"] = String(describing: error)"#,
            #"diagnostics["x"] = "failed: \(error)""#,
            #"recordDiagnostic("quickAccessBookmarkError", String(describing: failure))"#,
            #"let text = (error as NSError).localizedDescription"#,
            #"reason: (error as? LocalizedError)?.errorDescription"#,
        ]
        for line in unsafe { XCTAssertTrue(Self.unsafeErrorText(in: line), line) }
        let safe = [
            #"diagnostics["localAudioSkim:x"] = "failed:\(SafeErrorText.describe(error))""#,
            #"diagnostics["x"] = String(describing: move)"#,
            #"diagnostics["errors"] = "\(errorCount)""#,
            #"let message = "terror""#,
        ]
        for line in safe { XCTAssertFalse(Self.unsafeErrorText(in: line), line) }
    }
}
