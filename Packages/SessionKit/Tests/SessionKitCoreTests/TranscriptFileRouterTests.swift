import Foundation
import XCTest
@testable import SessionKit

/// #2997: which files are transcripts, what the item's text is, and what a listener reads when a file is refused.
final class TranscriptFileRouterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func route(_ name: String, _ text: String, docx: String? = nil) -> TranscriptFileRouter.Route {
        TranscriptFileRouter.route(fileName: name, data: Data(text.utf8), docxText: { _ in
            guard let docx else { throw TestFailure.unreadable }
            return docx
        }, timeZone: utc)
    }

    private enum TestFailure: Error { case unreadable }

    private func isTranscript(_ route: TranscriptFileRouter.Route) -> Bool {
        if case .transcript = route { return true }
        return false
    }

    // MARK: Sniffing

    func testTheFourPlainTextFixturesAreTranscripts() {
        for name in ["meet.txt", "otter.txt", "teams-docx.txt", "zoom-captions.txt"] {
            XCTAssertTrue(isTranscript(route(name, TranscriptFixtures.all[name]!)), name)
            XCTAssertNotNil(TranscriptFileRouter.isTranscript(text: TranscriptFixtures.all[name]!, timeZone: utc), name)
        }
    }

    func testTextThatIsNotATranscriptStaysOrdinaryText() {
        let rows: [(String, String)] = [
            ("agenda", "Agenda\n9:00 Welcome\n9:30 Budget review\n10:00 Break\n10:15 Roadmap\n"),
            ("recipe", "Pancakes\nMix the flour and milk.\nRest the batter 0:10\nFry each side 2:00\nServe warm.\n"),
            ("lyrics", "Verse one\nSomething in the water\nSomething in the air\nChorus\nSing it all together\n"),
            ("chat log", "Alice: are you coming?\nBen: running late\nAlice: ok see you there\n"),
            ("prose with two times", "We meet at\n10:00\nand again at\n10:00\nin the lobby.\n"),
            ("one cue", "Alice  0:03\nA single line of speech.\n"),
            ("one-cue srt-shaped text", "1\n00:00:01,000 --> 00:00:02,000\nAlice: Hi.\n"),
            ("prose before a transcript", (1...9).map { "A line of background number \($0)" }.joined(separator: "\n") + "\n\nAlice  0:03\nHello.\n\nBen  0:06\nHi.\n"),
            ("speakers on too few cues", "0:03\nOne.\n\n0:06\nTwo.\n\nAlice  0:09\nThree.\n\n0:12\nFour.\n")
        ]
        for (name, text) in rows {
            guard case let .notTranscript(returned) = route("\(name).txt", text) else { return XCTFail("\(name) was taken as a transcript") }
            XCTAssertEqual(returned, text, name)
            XCTAssertNil(TranscriptFileRouter.isTranscript(text: text, timeZone: utc), name)
        }
    }

    func testTheRuleCountsEightPreambleLinesAsEnough() {
        func file(preamble: Int) -> String {
            (1...preamble).map { "Background line \($0)" }.joined(separator: "\n") + "\n\nAlice  0:03\nHello.\n\nBen  0:06\nHi.\n"
        }
        XCTAssertTrue(isTranscript(route("a.txt", file(preamble: 8))))
        XCTAssertFalse(isTranscript(route("a.txt", file(preamble: 9))))
    }

    func testVTTAndSRTMustParseWhateverTheirSpeakers() {
        XCTAssertTrue(isTranscript(route("one.vtt", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nOnly line.\n")))
        XCTAssertTrue(isTranscript(route("one.srt", "1\n00:00:01,000 --> 00:00:02,000\nOnly line.\n")))
        assertFailure(route("notes.vtt", "WEBVTT\n\nJust some words.\n"), .noTimedLines)
        assertFailure(route("notes.srt", "Just some words.\n"), .noTimedLines)
    }

    func testEveryFixtureRoutesByItsOwnExtension() {
        for (name, text) in TranscriptFixtures.all {
            XCTAssertTrue(isTranscript(route(name, text)), name)
        }
    }

    func testEmptyFilesAreRefusedWhateverTheirType() {
        for name in ["a.vtt", "a.srt", "a.txt", "a.docx"] {
            assertFailure(route(name, " \n\t", docx: "  \n"), .empty, name)
            assertFailure(TranscriptFileRouter.route(fileName: name, data: Data(), docxText: { _ in throw TestFailure.unreadable }), .empty, name)
        }
    }

    func testDocxRoutes() {
        XCTAssertTrue(isTranscript(route("Budget.docx", "unused", docx: TranscriptFixtures.all["teams-docx.txt"]!)))
        guard case let .notTranscript(text) = route("Letter.docx", "unused", docx: "Dear Sam,\n\nThanks for the note.\n") else { return XCTFail() }
        XCTAssertEqual(text, "Dear Sam,\n\nThanks for the note.\n")
        assertFailure(route("Broken.docx", "unused", docx: nil), .docxUnreadable)
    }

    func testSizeLimitByType() {
        let big = Data(repeating: UInt8(ascii: "a"), count: TranscriptImport.maximumBytes + 1)
        for name in ["a.vtt", "a.srt", "a.docx"] {
            assertFailure(TranscriptFileRouter.route(fileName: name, data: big, docxText: { _ in "x" }), .tooLarge, name)
        }
        // A `.txt` over the cap isn't sniffed; it keeps today's text import.
        guard case let .notTranscript(text) = TranscriptFileRouter.route(fileName: "a.txt", data: big, docxText: { _ in "" }) else { return XCTFail() }
        XCTAssertEqual(text.utf8.count, big.count)
        let notUTF8 = Data(repeating: 0xE9, count: TranscriptImport.maximumBytes + 1)
        assertFailure(TranscriptFileRouter.route(fileName: "a.txt", data: notUTF8, docxText: { _ in "" }), .couldNotRead)
    }

    func testANonTranscriptTextFileKeepsTodaysUTF8OnlyRead() throws {
        let latin = try XCTUnwrap("Café menu\nTea 2:00\nCake 3:00\n".data(using: .windowsCP1252))
        assertFailure(TranscriptFileRouter.route(fileName: "menu.txt", data: latin, docxText: { _ in "" }), .couldNotRead)
        let utf16 = Data([0xFF, 0xFE]) + "Café menu, no times here.\n".data(using: .utf16LittleEndian)!
        assertFailure(TranscriptFileRouter.route(fileName: "menu.txt", data: utf16, docxText: { _ in "" }), .couldNotRead)
        guard case let .notTranscript(text) = route("menu.txt", "Café menu\nTea and cake.\n") else { return XCTFail() }
        XCTAssertEqual(text, "Café menu\nTea and cake.\n")
    }

    func testAFileOfOnlyLineSeparatorsHasNoSpeech() {
        assertFailure(route("a.vtt", "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n\u{2028}\n\n00:00:03.000 --> 00:00:04.000\n\u{85}\n"), .noTimedLines)
    }

    func testUTF16TranscriptTextIsFound() {
        let data = Data([0xFF, 0xFE]) + TranscriptFixtures.all["zoom-captions.txt"]!.data(using: .utf16LittleEndian)!
        guard case let .transcript(transcript) = TranscriptFileRouter.route(fileName: "captions.txt", data: data, docxText: { _ in "" }, timeZone: utc) else {
            return XCTFail()
        }
        XCTAssertEqual(transcript.cues.count, 3)
    }

    private func assertFailure(_ route: TranscriptFileRouter.Route, _ kind: TranscriptImportMessage.Kind, _ name: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case let .failed(message) = route else { return XCTFail("\(name): expected \(kind), got \(route)", file: file, line: line) }
        XCTAssertEqual(message.kind, kind, name, file: file, line: line)
    }

    // MARK: Messages

    func testEveryMessageReachesTheListenerUnchangedWithAZoomStyleName() {
        let name = "GMT20261112-150000_Recording.transcript.vtt"
        let kinds: [TranscriptImportMessage.Kind] = [.empty, .noTimedLines, .tooLarge, .docxUnreadable, .docxNotATranscript, .couldNotRead, .unsupportedType]
        for kind in kinds {
            let message = TranscriptImportMessage(kind, fileName: name)
            let shown = ListenerErrorText.message(for: message)
            XCTAssertEqual(shown, message.errorDescription, "\(kind)")
            XCTAssertNotEqual(shown, ListenerErrorText.fallback, "\(kind)")
            XCTAssertTrue(shown.contains("\u{201C}\(name)\u{201D}"), "\(kind)")
        }
        XCTAssertEqual(TranscriptImportMessage(.empty, fileName: name).errorDescription, "\u{201C}\(name)\u{201D} is empty, so nothing was added.")
        XCTAssertEqual(TranscriptImportMessage(.tooLarge, fileName: "a.vtt").errorDescription, "\u{201C}a.vtt\u{201D} is larger than 10 MB, so nothing was added.")
    }

    func testAnOddFileNameIsShownOnOneShortLine() {
        XCTAssertEqual(TranscriptImportMessage(.empty, fileName: "Budget\nsync\t \u{7}notes.vtt").displayName, "Budget sync notes.vtt")
        XCTAssertEqual(TranscriptImportMessage(.empty, fileName: "   ").displayName, "this file")
        let long = String(repeating: "a", count: 200) + ".vtt"
        XCTAssertEqual(TranscriptImportMessage(.empty, fileName: long).displayName.count, 60)
        XCTAssertTrue(TranscriptImportMessage(.empty, fileName: long).displayName.hasSuffix("\u{2026}"))
    }
}
