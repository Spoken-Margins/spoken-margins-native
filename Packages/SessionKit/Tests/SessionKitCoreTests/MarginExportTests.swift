import Foundation
import XCTest
@testable import SessionKit

/// #3211: "Export this Margin" hands over the note, and for a voice Margin its recording too. Real temporary files.
final class MarginExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testTheOfferFollowsWhatTheMarginHasOnThisPhone() {
        XCTAssertEqual(MarginExportOffer.offer(hasNote: true, recordingIsOnThisPhone: false), .textOnly, "a written Margin")
        XCTAssertEqual(MarginExportOffer.offer(hasNote: true, recordingIsOnThisPhone: true), .askTextOrAudio)
        XCTAssertEqual(MarginExportOffer.offer(hasNote: false, recordingIsOnThisPhone: true), .audioOnly, "no words yet")
        XCTAssertEqual(MarginExportOffer.offer(hasNote: false, recordingIsOnThisPhone: false), .nothing)
    }

    func testAudioAndTextAreCopiesBesideEachOtherWithOneName() throws {
        let recording = try recordingFile("take.m4a", bytes: "AUDIO")
        let note = MarginMarkdownFile(fileName: "Margin - An essay - 12m04s.md", markdown: "# A thought\n")
        let files = try MarginExport.prepare(markdown: note, recording: recording, audioBaseName: "unused", into: root.appendingPathComponent("out"))

        XCTAssertEqual(files.markdownURL?.lastPathComponent, "Margin - An essay - 12m04s.md")
        XCTAssertEqual(files.audioURL?.lastPathComponent, "Margin - An essay - 12m04s.m4a")
        XCTAssertEqual(files.audioURL?.deletingLastPathComponent(), files.markdownURL?.deletingLastPathComponent())
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.audioURL), encoding: .utf8), "AUDIO")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.markdownURL), encoding: .utf8), "# A thought\n")
        XCTAssertEqual(files.shareURLs.map(\.pathExtension), ["m4a", "md"], "audio first")
        XCTAssertFalse(files.recordingLeftOut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path), "the Margin's own recording is only read")
    }

    func testTextOnlyHasNoAudio() throws {
        let note = MarginMarkdownFile(fileName: "Margin - A - 5%.md", markdown: "x")
        let files = try MarginExport.prepare(markdown: note, recording: nil, audioBaseName: "unused", into: root)
        XCTAssertNil(files.audioURL)
        XCTAssertFalse(files.recordingLeftOut, "no recording was asked for")
        XCTAssertEqual(files.shareURLs.count, 1)
    }

    func testARecordingWithNoExtensionIsCopiedAsM4aAndANoteNameWithoutMdKeepsItsStem() throws {
        let recording = try recordingFile("take", bytes: "A")
        let note = MarginMarkdownFile(fileName: "Margin - A - 1m00s", markdown: "words")
        let files = try MarginExport.prepare(markdown: note, recording: recording, audioBaseName: "unused", into: root.appendingPathComponent("out"))
        XCTAssertEqual(files.audioURL?.lastPathComponent, "Margin - A - 1m00s.m4a")
        XCTAssertEqual(files.markdownURL?.lastPathComponent, "Margin - A - 1m00s")
    }

    func testAMarginWithNoWordsYetExportsItsAudioUnderTheBaseName() throws {
        let recording = try recordingFile("take.wav", bytes: "RIFF")
        let files = try MarginExport.prepare(markdown: nil, recording: recording, audioBaseName: "Margin - An essay - 3m00s", into: root)
        XCTAssertNil(files.markdownURL)
        XCTAssertEqual(files.audioURL?.lastPathComponent, "Margin - An essay - 3m00s.wav")
    }

    func testAnUnreadableRecordingFallsBackToTheWordsAndSaysSo() throws {
        let note = MarginMarkdownFile(fileName: "Margin - A - 1m00s.md", markdown: "words")
        let missing = root.appendingPathComponent("gone.m4a")
        let files = try MarginExport.prepare(markdown: note, recording: missing, audioBaseName: "unused", into: root.appendingPathComponent("out"))
        XCTAssertNil(files.audioURL)
        XCTAssertTrue(files.recordingLeftOut)
        XCTAssertEqual(files.shareURLs, [try XCTUnwrap(files.markdownURL)])
    }

    func testASymbolicLinkIsNotACopiedRecording() throws {
        let target = try recordingFile("secret.m4a", bytes: "S")
        let link = root.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let note = MarginMarkdownFile(fileName: "Margin - A - 1m00s.md", markdown: "words")
        let files = try MarginExport.prepare(markdown: note, recording: link, audioBaseName: "unused", into: root.appendingPathComponent("out"))
        XCTAssertNil(files.audioURL)
        XCTAssertTrue(files.recordingLeftOut)
    }

    func testNothingToExportLeavesNoFolderBehind() throws {
        let out = root.appendingPathComponent("out")
        XCTAssertThrowsError(try MarginExport.prepare(markdown: nil, recording: nil, audioBaseName: "x", into: out)) {
            XCTAssertEqual($0 as? MarginExportError, .nothingToExport)
        }
        XCTAssertThrowsError(try MarginExport.prepare(markdown: nil, recording: root.appendingPathComponent("gone.m4a"), audioBaseName: "x", into: out)) {
            XCTAssertEqual($0 as? MarginExportError, .nothingToExport)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertEqual(leftovers, [], "a failed export removes its folder")
    }

    func testDiscardRemovesTheFolder() throws {
        let note = MarginMarkdownFile(fileName: "Margin - A - 1m00s.md", markdown: "words")
        let files = try MarginExport.prepare(markdown: note, recording: nil, audioBaseName: "x", into: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.folderURL.path))
        files.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folderURL.path))
    }

    func testTheAudioBaseNameTableCoversTitlesAndPositions() {
        func name(_ title: String, ms: Int?, percent: Int = 40) -> String {
            MarginExport.audioBaseName(itemTitle: title, margin: margin(mediaTimeMs: ms, percent: percent))
        }
        XCTAssertEqual(name("An essay", ms: 724_000), "Margin - An essay - 12m04s")
        XCTAssertEqual(name("An essay", ms: 3_723_000), "Margin - An essay - 1h02m03s")
        XCTAssertEqual(name("An essay", ms: nil, percent: 40), "Margin - An essay - 40%")
        XCTAssertEqual(name("a/b: c", ms: 0), "Margin - a-b- c - 00m00s", "path characters become dashes")
        XCTAssertEqual(name("", ms: 1000), "Margin - Untitled - 00m01s")
        XCTAssertEqual(name("  ..hidden.  ", ms: 1000), "Margin - hidden - 00m01s")
        XCTAssertEqual(name("日本語の記事", ms: 1000), "Margin - 日本語の記事 - 00m01s", "Unicode stays")
        XCTAssertLessThanOrEqual(name(String(repeating: "é", count: 400), ms: 1000).utf8.count, 200, "long titles are cut")
    }

    private func recordingFile(_ name: String, bytes: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func margin(mediaTimeMs: Int?, percent: Int) -> Interjection {
        Interjection(
            id: "m1", itemId: "item-1", sessionId: "session-1", targetType: .item, targetId: "item-1",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000), roughPercent: percent,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: mediaTimeMs),
            audioPath: "interjections/m1.m4a", audioStatus: "saved",
            transcriptionStatus: "transcribed", transcript: "Thought.", cleanedTranscript: nil,
            displayText: nil, status: "active", captureKind: nil
        )
    }
}
