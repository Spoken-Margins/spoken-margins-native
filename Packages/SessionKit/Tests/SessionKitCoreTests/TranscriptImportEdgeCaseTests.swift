import Foundation
import XCTest
@testable import SessionKit

/// #2997: the neighbouring inputs of a transcript file (encodings, line endings, missing times, odd speakers,
/// size), one row each. Each row names the file a listener could bring from a meeting app or an old tool.
final class TranscriptImportEdgeCaseTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func parse(_ data: Data) throws -> ImportedTranscript { try TranscriptImport.parse(data: data, timeZone: utc) }
    private func parse(_ text: String) throws -> ImportedTranscript { try TranscriptImport.parse(text: text, timeZone: utc) }

    private let srt = "1\n00:00:03,500 --> 00:00:06,000\nAlice Example: Welcome.\n\n2\n00:00:06,500 --> 00:00:09,000\nBen Sample: Thanks.\n"

    // MARK: Empty files

    func testEmptyWhitespaceAndBOMOnlyFilesAreEmpty() {
        let rows: [(String, Data)] = [
            ("zero bytes", Data()),
            ("whitespace", Data(" \n\t\r\n ".utf8)),
            ("UTF-8 BOM only", Data([0xEF, 0xBB, 0xBF])),
            ("UTF-16 LE BOM only", Data([0xFF, 0xFE])),
            ("UTF-16 BE BOM only", Data([0xFE, 0xFF])),
            ("one stray byte", Data([0x0A]))
        ]
        for (name, data) in rows {
            XCTAssertThrowsError(try parse(data), name) { XCTAssertEqual($0 as? TranscriptImport.Failure, .empty, name) }
        }
    }

    // MARK: Encodings

    func testEveryEncodingOfTheSameFileGivesTheSameCues() throws {
        let expected = try parse(srt)
        XCTAssertEqual(expected.cues.count, 2)
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + Data(srt.utf8)
        let utf16LEBOM = Data([0xFF, 0xFE]) + srt.data(using: .utf16LittleEndian)!
        let utf16BEBOM = Data([0xFE, 0xFF]) + srt.data(using: .utf16BigEndian)!
        let utf16LENoBOM = srt.data(using: .utf16LittleEndian)!
        let utf16BENoBOM = srt.data(using: .utf16BigEndian)!
        let rows: [(String, Data)] = [
            ("UTF-8", Data(srt.utf8)), ("UTF-8 BOM", utf8BOM), ("UTF-16 LE BOM", utf16LEBOM),
            ("UTF-16 BE BOM", utf16BEBOM), ("UTF-16 LE, no BOM", utf16LENoBOM), ("UTF-16 BE, no BOM", utf16BENoBOM)
        ]
        for (name, data) in rows {
            XCTAssertEqual(try parse(data).cues, expected.cues, name)
        }
    }

    func testUTF16WithAccentsAndNoBOMKeepsThem() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nJosé Núñez: ¿Qué tal?\n"
        let transcript = try parse(text.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(transcript.cues.first?.speaker, "José Núñez")
        XCTAssertEqual(transcript.cues.first?.text, "¿Qué tal?")
    }

    func testWindowsCodePageFilesKeepTheirLetters() throws {
        let text = "1\n00:00:03,500 --> 00:00:06,000\nJosé: Hola, it\u{2019}s Zoë\u{2019}s turn.\n"
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        XCTAssertNil(String(data: data, encoding: .utf8), "the fixture must not be valid UTF-8")
        let cue = try XCTUnwrap(try parse(data).cues.first)
        XCTAssertEqual(cue.speaker, "José")
        XCTAssertEqual(cue.text, "Hola, it\u{2019}s Zoë\u{2019}s turn.")
    }

    func testAByteWindows1252LeavesUndefinedStillReads() throws {
        var data = Data("1\n00:00:03,500 --> 00:00:06,000\nZo".utf8)
        data.append(contentsOf: [0xEB, 0x81]) // ë, then 0x81, which Windows-1252 leaves undefined
        data.append(Data(": Hello.\n".utf8))
        let cue = try XCTUnwrap(try parse(data).cues.first)
        XCTAssertEqual(cue.text, "Hello.")
        XCTAssertTrue(try XCTUnwrap(cue.speaker).hasPrefix("Zoë"))
    }

    func testDecodingNeverPicksUTF16ForAnEnglishFile() {
        // Zero bytes on both parities, or too few of them, are not UTF-16.
        XCTAssertEqual(TranscriptImport.decode(Data("plain ascii".utf8)), "plain ascii")
        XCTAssertEqual(TranscriptImport.decode(Data([0x61, 0x00, 0x00, 0x62])), "a\u{0}\u{0}b")
    }

    // MARK: Speakers

    func testDecomposedAndComposedSpellingsAreOneSpeaker() throws {
        let nfd = "Zoe\u{0308}", nfc = "Zo\u{00EB}"
        XCTAssertNotEqual(nfd.unicodeScalars.count, nfc.unicodeScalars.count)
        let text = "1\n00:00:01,000 --> 00:00:02,000\n\(nfd): One.\n\n2\n00:00:03,000 --> 00:00:04,000\n\(nfc): Two.\n"
        let cues = try parse(text).cues
        XCTAssertEqual(cues.map(\.speaker), [nfc, nfc])
        XCTAssertEqual(Set(cues.compactMap(\.speaker)).count, 1)
        XCTAssertEqual(cues.compactMap(\.speaker).map { $0.unicodeScalars.count }, [3, 3])
    }

    func testALabelIsNotASpeaker() throws {
        let cues = try parse("1\n00:00:01,000 --> 00:00:02,000\nNote: see below\n\n2\n00:00:03,000 --> 00:00:04,000\nAction items: send the deck\n\n3\n00:00:05,000 --> 00:00:06,000\nNotes: Ben Sample: hi\n").cues
        XCTAssertEqual(cues.map(\.speaker), [nil, nil, nil])
        XCTAssertEqual(cues.first?.text, "Note: see below")
        XCTAssertEqual(TranscriptImport.namePrefix("Ben Sample: Thanks.")?.0, "Ben Sample")
        XCTAssertEqual(TranscriptImport.namePrefix("Noted Person: Hi")?.0, "Noted Person")
        XCTAssertEqual(TranscriptImport.namePrefix("Question: How did it start?")?.0, "Question") // an interview's labels stay speakers
    }

    func testPlainTextCueKeepsItsSpeakerWhenTheTextStartsWithALabel() throws {
        let cues = try parse("Alice  0:03\nNote: see below\n\nBen  0:06\nOk.\n").cues
        XCTAssertEqual(cues.map(\.speaker), ["Alice", "Ben"])
        XCTAssertEqual(cues.first?.text, "Note: see below")
    }

    func testVTTWithNoSpeakersAndAnSRTWithNamePrefixes() throws {
        let vtt = try parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nOne.\n\n00:00:03.000 --> 00:00:04.000\nTwo.\n")
        XCTAssertEqual(vtt.cues.map(\.speaker), [nil, nil])
        XCTAssertEqual(try parse(srt).cues.map(\.speaker), ["Alice Example", "Ben Sample"])
    }

    // MARK: Line endings, order, times

    func testLineEndingsDontChangeTheCues() throws {
        let expected = try parse(srt).cues
        XCTAssertEqual(try parse(srt.replacingOccurrences(of: "\n", with: "\r\n")).cues, expected)
        XCTAssertEqual(try parse(srt.replacingOccurrences(of: "\n", with: "\r")).cues, expected)
    }

    func testCuesAreSortedByStartAndTiesKeepFileOrder() throws {
        let text = "WEBVTT\n\n00:00:05.000 --> 00:00:06.000\nLast.\n\n00:00:01.000 --> 00:00:02.000\nFirst tie.\n\n00:00:01.000 --> 00:00:02.500\nSecond tie.\n\n00:00:00.500 --> 00:00:00.900\nVery first.\n"
        XCTAssertEqual(try parse(text).cues.map(\.text), ["Very first.", "First tie.", "Second tie.", "Last."])
        let plain = "Ben  0:09\nLate.\n\nAlice  0:03\nTie one.\n\nCara  0:03\nTie two.\n"
        XCTAssertEqual(try parse(plain).cues.map(\.text), ["Tie one.", "Tie two.", "Late."])
    }

    func testACueWithoutAnEndEndsAtTheNextOne() throws {
        let cues = try parse("Alice  0:03\nOne.\n\nBen  0:06\nTwo.\n\nAlice  0:09\nThree.\n").cues
        XCTAssertEqual(cues.map(\.endMs), [6_000, 9_000, nil])
        XCTAssertEqual(try parse("Alice  0:03\nOne.\n\nBen  0:06\nTwo.\n\nAlice  0:09\nThree.\n").durationMs, 9_000)
    }

    func testTimesPastTenHours() throws {
        let vtt = try parse("WEBVTT\n\n10:00:03.000 --> 10:00:05.000\nLate in the day.\n\n100:00:00.000 --> 100:00:01.000\nVery long.\n")
        XCTAssertEqual(vtt.cues.map(\.startMs), [36_003_000, 360_000_000])
        let teams = try parse("Alice  10 hours 2 minutes 3 seconds\nHello.\n").cues
        XCTAssertEqual(teams.first?.startMs, 36_123_000)
    }

    func testACueWithNoTextIsDropped() throws {
        let text = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n\n00:00:03.000 --> 00:00:04.000\nSpoken.\n\n00:00:05.000 --> 00:00:06.000\n<v Ben></v>\n"
        XCTAssertEqual(try parse(text).cues.map(\.text), ["Spoken."])
    }

    // MARK: The preamble

    func testPreambleLinesAreCounted() throws {
        let counts = try TranscriptFixtures.all.mapValues { try parse($0).skippedHeaderLineCount }
        XCTAssertEqual(counts["teams-docx.txt"], 4)
        XCTAssertEqual(counts["meet.txt"], 4)
        XCTAssertEqual(counts["otter.txt"], 2)
        XCTAssertEqual(counts["zoom-captions.txt"], 0)
        for name in ["teams.vtt", "zoom.vtt", "webex.vtt", "generic.srt"] { XCTAssertEqual(counts[name], 0, name) }
    }

    func testPreambleOfCueFormatsSkipsTheFormatsOwnLines() throws {
        let vtt = "\u{FEFF}WEBVTT\n\nNOTE written by hand\nsecond note line\n\nSTYLE\n::cue { color: red }\n\nREGION\nid:a\n\nabc/1-0\n00:00:01.000 --> 00:00:02.000\nHi.\n"
        XCTAssertEqual(try parse(vtt).skippedHeaderLineCount, 0)
        XCTAssertEqual(try parse("WEBVTT\nKind: captions\nLanguage: en\n\n00:00:01.000 --> 00:00:02.000\nHi.\n").skippedHeaderLineCount, 0)
        let prose = "Weekly agenda\nItem one\n\n3\n00:00:01.000 --> 00:00:02.000\nHi.\n"
        XCTAssertEqual(try parse(prose).skippedHeaderLineCount, 2)
    }

    func testATranscriptDecodedFromOlderJSONHasNoPreamble() throws {
        let json = #"{"format":"srt","cues":[{"startMs":1000,"text":"Hi."}]}"#
        let decoded = try JSONDecoder().decode(ImportedTranscript.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.skippedHeaderLineCount, 0)
        let roundTrip = try JSONDecoder().decode(ImportedTranscript.self, from: JSONEncoder().encode(try parse(TranscriptFixtures.all["meet.txt"]!)))
        XCTAssertEqual(roundTrip.skippedHeaderLineCount, 4)
    }

    // MARK: Size and speed

    private func longVTT(cues: Int) -> String {
        var lines = ["WEBVTT", ""]
        lines.reserveCapacity(cues * 4)
        for index in 0..<cues {
            let start = index * 1_000
            lines.append("\(index + 1)")
            lines.append("\(clock(start)) --> \(clock(start + 900))")
            lines.append("<v Speaker \(index % 4)>This is sentence number \(index) of a long meeting.</v>")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func clock(_ ms: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1_000 % 60, ms % 1_000)
    }

    func testTenThousandCuesParseInUnderTwoSeconds() throws {
        let vtt = longVTT(cues: 10_000)
        let started = Date()
        let transcript = try parse(Data(vtt.utf8))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(transcript.cues.count, 10_000)
        XCTAssertEqual(transcript.cues.last?.speaker, "Speaker 3")
        XCTAssertLessThan(elapsed, 2, "10,000 cues took \(elapsed) s")
    }

    func testTenThousandPlainTextCuesParseInUnderTwoSeconds() throws {
        var lines = ["Long meeting", "Mar 4, 2026 10:00 AM", ""]
        for index in 0..<10_000 {
            lines.append("Speaker \(index % 4)  \(index / 60):\(String(format: "%02d", index % 60))")
            lines.append("This is sentence number \(index) of a long meeting.")
            lines.append("")
        }
        let started = Date()
        let transcript = try parse(Data(lines.joined(separator: "\n").utf8))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(transcript.cues.count, 10_000)
        XCTAssertLessThan(elapsed, 2, "10,000 plain-text cues took \(elapsed) s")
    }

    func testTheSizeLimitIsTenMegabytes() throws {
        XCTAssertEqual(TranscriptImport.maximumBytes, 10_000_000)
        let head = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nSpeaker: "
        func file(bytes: Int) -> Data { Data(head.utf8) + Data(repeating: UInt8(ascii: "a"), count: bytes - head.utf8.count) }
        XCTAssertEqual(try parse(file(bytes: 9_900_000)).cues.count, 1)
        XCTAssertThrowsError(try parse(file(bytes: 10_000_001))) { XCTAssertEqual($0 as? TranscriptImport.Failure, .tooLarge) }
        XCTAssertThrowsError(try parse(file(bytes: 10_100_000))) { XCTAssertEqual($0 as? TranscriptImport.Failure, .tooLarge) }
        XCTAssertEqual(TranscriptImport.Failure.tooLarge.errorDescription, "The transcript file is larger than 10 MB.")
    }
}
