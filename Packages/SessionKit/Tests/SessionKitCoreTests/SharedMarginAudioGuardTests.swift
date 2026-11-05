import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #3412 audit, the second miss in the written-Margin work: the Timeline tap read a friend's `audioPath` itself and so
/// could not play a written Margin. The class is "a way of playing a friend's Margin that decides for itself what it
/// sounds like". The cure is `SharedMarginAudio`: every playing path asks it. This scans the app's sources for any read of
/// `.audioPath` and fails on one that is not on the list below. A new line that plays a friend's Margin belongs in
/// `SharedMarginAudio`; a new line about something else (your own recording, sharing, deleting) is added here with its reason.
final class SharedMarginAudioGuardTests: XCTestCase {
    /// Files whose every read of `.audioPath` is about something other than playing a friend's Margin.
    static let otherThanPlayingAFriendsMargin: [String: String] = [
        "PlayerRunController.swift": "a Margin the Watch recorded on a run: the listener's own",
        "WatchMarginReceiver.swift": "a Margin the Watch recorded: the listener's own",
        "LiveSessionController.swift": "the listener's own live-session recordings",
        "LiveSessionSpokenMargins.swift": "the listener's own live-session recordings",
        "ExportScreen.swift": "sharing the listener's own Margins (has a voice or not)",
        "Gate1AppModel+ShareExport.swift": "sharing the listener's own Margins",
        "Gate1AppModel+ShareDrafts.swift": "sharing the listener's own Margins",
        "Build23SharingSeams.swift": "sharing the listener's own Margins",
        "Gate1AppModel+PermanentDeleteFiles.swift": "deleting recording files",
        "Gate1AppModel+SourceWindowContext.swift": "transcribing the listener's own recordings",
        "Gate1AppModel+ListeningSignals.swift": "a signal about the listener's own spoken Margin",
        "ExperienceModels.swift": "the row of the listener's own Margin (`MarginRow`)",
        "Gate1RootView.swift": "the controls on the listener's own Margin",
        "Gate1AppModel+MarginLeveling.swift": "making level-matched copies ahead of time; a reading is leveled when it plays",
    ]

    /// Single lines, by file and text, in files that also play friends' Margins.
    static let ownMarginLines: [String: String] = [
        "Gate1AppModel+MarginVoicePlayback.swift::guard let audioPath = interjection.audioPath,": "your own Margin's playback",
        "Gate1AppModel+MarginVoicePlayback.swift::if let path = margin.audioPath { voiceURLs[Self.marginIdentity(margin)] = resolvedInterjectionAudioURL(for: path) }": "your own spoken Margins in a moment",
        "Gate1AppModel+SharedMarginReview.swift::guard let url = parent.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) else { return false }": "the listener's own Margin a reply answers",
    ]

    /// The lines of `source` that read `.audioPath`, with comments and strings' trailing comments left out.
    static func reads(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { return nil }
            if let comment = line.range(of: " // ") { line = String(line[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            return line.range(of: #"\.audioPath\b"#, options: .regularExpression) == nil ? nil : line
        }
    }

    private func appSourceFiles() throws -> [(name: String, source: String)] {
        let directory = try TestInputs.directory(.appSources)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(names.count, 50, "The scan found the app's sources")
        return try names.map { ($0, try String(contentsOf: directory.appending(path: $0), encoding: .utf8)) }
    }

    func testNoPathReadsAFriendsRecordingPathItself() throws {
        var offences: [String] = []
        for (name, source) in try appSourceFiles() where Self.otherThanPlayingAFriendsMargin[name] == nil {
            for line in Self.reads(in: source) where Self.ownMarginLines["\(name)::\(line)"] == nil {
                offences.append("\(name): \(line)")
            }
        }
        XCTAssertEqual(offences, [], "Ask SharedMarginAudio (`WrittenMarginReadings.audio(for:in:voiceFile:)`, `SharedMarginAudio.canOffer`) instead of reading audioPath, or list the line here with its reason")
    }

    /// A list that outlives the code it excuses would excuse a future line; this is how it stays honest.
    func testEveryListedExcuseStillMatchesSomething() throws {
        let files = try appSourceFiles()
        let names = Set(files.map(\.name))
        for name in Self.otherThanPlayingAFriendsMargin.keys {
            XCTAssertTrue(names.contains(name), "\(name) is gone: take it off the list")
            let reads = Self.reads(in: files.first { $0.name == name }?.source ?? "")
            XCTAssertFalse(reads.isEmpty, "\(name) no longer reads audioPath: take it off the list")
        }
        let all = Set(files.flatMap { file in Self.reads(in: file.source).map { "\(file.name)::\($0)" } })
        for key in Self.ownMarginLines.keys { XCTAssertTrue(all.contains(key), "No longer in the source: \(key)") }
    }

    func testTheScannerSeesTheWaysAPathReadsIt() {
        XCTAssertEqual(Self.reads(in: "guard let voiceURL = row.interjection.audioPath.flatMap(resolvedApplicationSupportAssetURL(for:)) else {").count, 1)
        XCTAssertEqual(Self.reads(in: "canPlay: row.interjection.audioPath != nil,").count, 1)
        XCTAssertEqual(Self.reads(in: "let paths = deleted.compactMap(\\.audioPath)").count, 1)
        XCTAssertEqual(Self.reads(in: "if let path = margin.audioPath { play(path) }").count, 1)
        XCTAssertTrue(Self.reads(in: "// row.interjection.audioPath is not read here").isEmpty)
        XCTAssertTrue(Self.reads(in: "let x = 1 // margin.audioPath, said in a note").isEmpty)
        XCTAssertTrue(Self.reads(in: "try await transcriptionClient.transcribe(audioPath: audioPath)").isEmpty, "an argument label is not a read")
    }
}
