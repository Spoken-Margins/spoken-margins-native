import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #3412 audit, the second miss in the written-Margin work: the Timeline tap read a friend's `audioPath` itself and so
/// could not play a written Margin; the review then found the item screen's Listen button hidden the same way, behind a
/// whole-file excuse. The class is "a way of playing, offering or hiding a friend's Margin that decides for itself what
/// it sounds like". The cure is `SharedMarginAudio`: every such path asks it.
///
/// This scans every app source (the app, the shared sources, the extensions, the widget and the Watch) for any read of
/// `.audioPath`. Each read must be one listed below as an exact line in its file, with the reason it is about something
/// other than a friend's Margin. There are no whole-file excuses: a new read in any file, listed or not, fails. A line
/// that plays, offers or hides a friend's Margin belongs in `SharedMarginAudio`; a line about something else (your own
/// recording, sharing, deleting) is added here, with its reason.
final class SharedMarginAudioGuardTests: XCTestCase {
    struct Excuse {
        let file: String
        let line: String
        let reason: String
        var count = 1
    }

    /// Paths are relative to `App/`. A line that appears twice in a file is one excuse with `count: 2`.
    static let excuses: [Excuse] = {
        let app = "SpokenMarginsApp/Sources/SpokenMarginsApp/"
        let fromWatch = "a Margin the Watch recorded: the listener's own"
        return [
            Excuse(file: app + "ExperienceModels.swift", line: "var canPlayRecording: Bool { !isWritten && interjection.audioPath != nil }",
                   reason: "the row of the listener's own Margin (`MarginRow`)"),
            Excuse(file: app + "ExperienceModels.swift", line: #"var canRetryTranscription: Bool { !isWritten && !["transcribed", "complete"].contains(interjection.transcriptionStatus) && interjection.audioPath != nil }"#,
                   reason: "retrying the transcription of the listener's own recording"),
            Excuse(file: app + "ExportScreen.swift", line: "SharedMarginTextRequirement.canShare($0, hasVoice: $0.audioPath.flatMap(model.resolvedInterjectionAudioURL(for:)) != nil)",
                   reason: "sharing the listener's own Margins (has a voice or not)"),
            Excuse(file: app + "Gate1AppModel+ListeningSignals.swift", line: "audioURL: interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)))",
                   reason: "a signal about the listener's own spoken Margin"),
            Excuse(file: app + "Gate1AppModel+MarginVoicePlayback.swift", line: "guard let audioPath = interjection.audioPath,",
                   reason: "your own Margin's playback (`Interjection`, not a friend's)"),
            Excuse(file: app + "Gate1AppModel+MarginVoicePlayback.swift", line: "if let path = margin.audioPath { voiceURLs[Self.marginIdentity(margin)] = resolvedInterjectionAudioURL(for: path) }",
                   reason: "your own spoken Margins in a moment (`spoken` is the listener's own Interjections)", count: 2),
            Excuse(file: app + "Gate1AppModel+MarginLeveling.swift", line: "guard let path = margin.audioPath, let url = resolvedInterjectionAudioURL(for: path) else { continue }",
                   reason: "making level-matched copies of the listener's own recordings ahead of time"),
            Excuse(file: app + "Gate1AppModel+MarginLeveling.swift", line: "guard let path = margin.audioPath, let url = resolvedApplicationSupportAssetURL(for: path) else { continue }",
                   reason: "making level-matched copies of friends' recordings ahead of time; neither offers nor plays them, and a reading is leveled when it plays"),
            Excuse(file: app + "Gate1AppModel+PermanentDeleteFiles.swift", line: "let deletedAudioPaths = deleted.compactMap(\\.audioPath) + quarantinedAudioPaths",
                   reason: "deleting recording files"),
            Excuse(file: app + "Gate1AppModel+ShareDrafts.swift", line: "hasVoice: interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) != nil,",
                   reason: "sharing the listener's own Margins"),
            Excuse(file: app + "Gate1AppModel+ShareDrafts.swift", line: "let audioPath = sharingState.drafts[analysisIndex].interjection.audioPath",
                   reason: "sharing the listener's own Margins"),
            Excuse(file: app + "Gate1AppModel+ShareDrafts.swift", line: "guard let sourcePath = sharingState.drafts[index].interjection.audioPath,",
                   reason: "sharing the listener's own Margins"),
            Excuse(file: app + "Gate1AppModel+ShareDrafts.swift", line: ".interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:))",
                   reason: "sharing the listener's own Margins"),
            Excuse(file: app + "Gate1AppModel+ShareDrafts.swift", line: "let sourcePath = sharingState.drafts[index].interjection.audioPath,",
                   reason: "sharing the listener's own Margins", count: 2),
            Excuse(file: app + "Gate1AppModel+ShareExport.swift", line: "return draft.interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:))",
                   reason: "sharing the listener's own Margins"),
            Excuse(file: app + "Gate1AppModel+ShareExport.swift", line: "guard let url = draft.interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)),",
                   reason: "sharing the listener's own Margins"),
            Excuse(file: app + "Gate1AppModel+SourceWindowContext.swift", line: #"return interjections.last { $0.transcriptionStatus == "pending" && $0.audioPath != nil }"#,
                   reason: "transcribing the listener's own recordings"),
            Excuse(file: app + "Gate1AppModel+SourceWindowContext.swift", line: "guard let audioPath = interjection.audioPath else { return }",
                   reason: "transcribing the listener's own recordings"),
            Excuse(file: app + "Gate1AppModel+SharedMarginReview.swift", line: "guard let url = parent.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) else { return false }",
                   reason: "the listener's own Margin a friend's reply answers (`parent` is an Interjection)"),
            Excuse(file: app + "Gate1RootView.swift", line: ".disabled(current.audioPath == nil)",
                   reason: "the controls on the listener's own Margin"),
            Excuse(file: app + "Gate1RootView.swift", line: ".disabled(current.audioPath == nil || model.isRetryingInterjectionTranscription(current))",
                   reason: "the controls on the listener's own Margin"),
            Excuse(file: app + "LiveSessionSpokenMargins.swift", line: "sessionId: sessionId, marginId: marginId, audioPath: recording.audioPath, markedAt: recording.startedAt,",
                   reason: "the listener's own live-session recordings"),
            Excuse(file: app + "LiveSessionSpokenMargins.swift", line: "guard let text = await LiveSessionSpokenMargins.transcribe(audioPath: recording.audioPath) else { return }",
                   reason: "the listener's own live-session recordings"),
            Excuse(file: app + "LiveSessionSpokenMargins.swift", line: "guard let text = await transcribe(audioPath: margin.audioPath) else { continue }",
                   reason: "the listener's own live-session recordings"),
            Excuse(file: app + "PlayerRunController.swift", line: "if let audioPath = placement.audioPath {", reason: fromWatch + " on a run"),
            Excuse(file: app + "PlayerRunController.swift", line: "let audioPath = WatchMarginTransfer(id: id, wallStart: Date(timeIntervalSince1970: 1), durationMs: 0).audioPath",
                   reason: fromWatch + " on a run"),
            Excuse(file: app + "WatchMarginReceiver.swift", line: "if let audioPath = placement.audioPath {", reason: fromWatch),
            Excuse(file: app + "WatchMarginReceiver.swift", line: "guard let text = await transcribe(margin.audioPath) else { continue }", reason: fromWatch),
        ]
    }()

    /// The lines of `source` that read `.audioPath`, with comments and strings' trailing comments left out.
    static func reads(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { return nil }
            if let comment = line.range(of: " // ") { line = String(line[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            return line.range(of: #"\.audioPath\b"#, options: .regularExpression) == nil ? nil : line
        }
    }

    /// The folders under `App/` that hold the app's shipping sources, with the input that finds each. Tests, UI tests,
    /// fixtures and resources are not shipping code. `testEveryAppFolderIsScannedOrIsNotSource` keeps this list whole.
    private static let sourceFolders: [(name: String, input: TestInputs.Input)] = [
        ("SpokenMarginsApp", .appSources), ("SharedSources", .appSharedSources), ("Gate2Shared", .appGate2Shared),
        ("SpokenMarginsBrowserTextExtension", .appBrowserTextExtension), ("SpokenMarginsShareExtension", .appShareExtension),
        ("SpokenMarginsGate2Widget", .appGate2Widget), ("SpokenMarginsWatch", .appWatch), ("SpokenMarginsWatchApp", .appWatchApp),
    ]
    private static let notShippingSource: Set<String> = [
        "SpokenMarginsAppTests", "SpokenMarginsAppUITests", "TestFixtures", "SharedResources",
    ]

    /// Every shipping Swift file, as its path relative to `App/`, with its text.
    private func appSourceFiles() throws -> [(path: String, source: String)] {
        var files: [(String, String)] = []
        for (name, input) in Self.sourceFolders {
            let root = try TestInputs.directory(input).standardizedFileURL
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                XCTFail("could not read \(root.path)"); continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/Tests/") {
                let relative = url.standardizedFileURL.path.replacingOccurrences(of: root.path + "/", with: "")
                let prefix = name == "SpokenMarginsApp" ? "SpokenMarginsApp/Sources/SpokenMarginsApp/" : name + "/"
                files.append((prefix + relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        XCTAssertGreaterThan(files.filter { $0.0.hasPrefix("SpokenMarginsApp/") }.count, 50, "The scan found the app's sources")
        return files.sorted { $0.0 < $1.0 }
    }

    func testNoPathReadsAFriendsRecordingPathItself() throws {
        var offences: [String] = []
        for (path, source) in try appSourceFiles() {
            var allowed: [String: Int] = [:]
            for excuse in Self.excuses where excuse.file == path { allowed[excuse.line, default: 0] += excuse.count }
            for line in Self.reads(in: source) {
                if let left = allowed[line], left > 0 { allowed[line] = left - 1 } else { offences.append("\(path): \(line)") }
            }
        }
        XCTAssertEqual(offences, [], "Ask SharedMarginAudio (`WrittenMarginReadings.audio(for:in:voiceFile:)`, `SharedMarginAudio.canOffer`) instead of reading audioPath, or list the exact line in `excuses` with its reason")
    }

    /// A list that outlives the code it excuses would excuse a future line; this is how it stays honest.
    func testEveryExcuseMatchesExactlyTheLinesItNames() throws {
        let files = try appSourceFiles()
        var found: [String: Int] = [:]
        for (path, source) in files { for line in Self.reads(in: source) { found["\(path)::\(line)", default: 0] += 1 } }
        var listed: [String: Int] = [:]
        for excuse in Self.excuses { listed["\(excuse.file)::\(excuse.line)", default: 0] += excuse.count }
        for (key, count) in listed { XCTAssertEqual(found[key] ?? 0, count, "The source has a different number of these lines than the list says: \(key)") }
        for excuse in Self.excuses { XCTAssertFalse(excuse.reason.isEmpty, "\(excuse.file) needs a reason") }
    }

    /// A new extension or target folder under `App/` must be scanned, or named as not shipping source.
    func testEveryAppFolderIsScannedOrIsNotSource() throws {
        let appRoot = try TestInputs.directory(.appSources).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = try FileManager.default.contentsOfDirectory(atPath: appRoot.path).filter {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: appRoot.appending(path: $0).path, isDirectory: &isFolder) && isFolder.boolValue
        }
        let known = Set(Self.sourceFolders.map(\.name)).union(Self.notShippingSource)
        XCTAssertEqual(Set(folders).subtracting(known), [], "A new folder under App/: scan it (add it to sourceFolders and TestInputs) or list it as not shipping source")
        XCTAssertEqual(known.subtracting(folders), [], "A listed folder is gone from App/")
    }

    func testTheScannerSeesTheWaysAPathReadsIt() {
        XCTAssertEqual(Self.reads(in: "guard let voiceURL = row.interjection.audioPath.flatMap(resolvedApplicationSupportAssetURL(for:)) else {").count, 1)
        XCTAssertEqual(Self.reads(in: "canPlay: row.interjection.audioPath != nil,").count, 1)
        XCTAssertEqual(Self.reads(in: "hasVoice: margin.audioPath != nil,").count, 1)
        XCTAssertEqual(Self.reads(in: "let paths = deleted.compactMap(\\.audioPath)").count, 1)
        XCTAssertEqual(Self.reads(in: "if let path = margin.audioPath { play(path) }").count, 1)
        XCTAssertTrue(Self.reads(in: "// row.interjection.audioPath is not read here").isEmpty)
        XCTAssertTrue(Self.reads(in: "let x = 1 // margin.audioPath, said in a note").isEmpty)
        XCTAssertTrue(Self.reads(in: "try await transcriptionClient.transcribe(audioPath: audioPath)").isEmpty, "an argument label is not a read")
    }
}
