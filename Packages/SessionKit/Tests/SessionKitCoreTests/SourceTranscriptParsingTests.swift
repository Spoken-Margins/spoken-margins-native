import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

final class SourceTranscriptParsingTests: XCTestCase {
    private func parse(_ body: String, type: String = "application/json", url: String = "https://example.test/transcript", durationMs: Int? = nil) throws -> TranscriptTimeline? {
        try SourceTranscriptParsing.transcriptTimeline(
            from: Data(body.utf8), link: SourceTranscriptLink(url: url, type: type),
            itemId: "episode-雪", durationMs: durationMs
        )
    }

    func testLinkPriorityAndStableTies() {
        let ranked = [
            SourceTranscriptLink(url: "a", type: "TEXT/VTT"),
            SourceTranscriptLink(url: "b", type: "", rel: "webvtt"),
            SourceTranscriptLink(url: "c.srt", type: ""),
            SourceTranscriptLink(url: "d", type: "application/subrip"),
            SourceTranscriptLink(url: "e", type: "application/json"),
            SourceTranscriptLink(url: "f", type: "text/plain"),
            SourceTranscriptLink(url: "g.txt", type: ""),
            SourceTranscriptLink(url: "h", type: "text/html"),
            SourceTranscriptLink(url: "i.htm", type: ""),
            SourceTranscriptLink(url: "j", type: "unknown"),
            SourceTranscriptLink(url: "k", type: "")
        ]
        let shuffled = [9, 7, 5, 4, 2, 0, 10, 8, 6, 3, 1].map { ranked[$0] }
        XCTAssertEqual(SourceTranscriptParsing.prioritizedTranscriptLinks(shuffled), ranked)
    }

    func testWebVTTSkipsNonCueBlocksAndKeepsIDsAndDispatchOrder() throws {
        let body = "WEBVTT\n\nNOTE ignored\nno timing here\n\ncue name\n00:01.500 --> 00:02.750 align:start\n<b>Hello</b>\n world\n\n00:03.000 --> 00:04.000\nNext"
        // URL vtt takes precedence over JSON, just as in the original app parser.
        let timeline = try XCTUnwrap(parse(body, url: "https://example.test/x.json?vtt=1"))
        XCTAssertEqual(timeline.segments.map(\.id), ["transcript-episode-雪-cue-0001", "transcript-episode-雪-cue-0002"])
        XCTAssertEqual(timeline.segments.map(\.text), ["Hello world", "Next"])
        XCTAssertEqual(timeline.segments.map(\.startMs), [1500, 3000])
        XCTAssertEqual(timeline.segments.map(\.endMs), [2750, 4000])
    }

    func testSRTCommaTimesAndCRLF() throws {
        let timeline = try XCTUnwrap(parse("1\r\n01:02:03,125 --> 01:02:04,500\r\nSRT line\r\n", type: "application/x-subrip", url: "https://example.test/a.srt"))
        XCTAssertEqual(timeline.segments.first?.startMs, 3_723_125)
        XCTAssertEqual(timeline.segments.first?.endMs, 3_724_500)
        XCTAssertEqual(timeline.segments.first?.text, "SRT line")
    }

    func testCueEndIsAtLeastStartPlusOne() throws {
        let timeline = try XCTUnwrap(parse("00:02 --> 00:01\nEarlier\n\n00:03 --> 00:03\nEqual", type: "text/vtt"))
        XCTAssertEqual(timeline.segments.map(\.endMs), [2001, 3001])
    }

    func testDurationFallsBackToLargestEndAndPreservesExplicitDuration() throws {
        for (body, type) in [
            ("00:04 --> 00:08\nFirst\n\n00:01 --> 00:02\nLast", "text/vtt"),
            (#"[{"text":"First","start":4000,"end":8000},{"text":"Last","start":1000,"end":2000}]"#, "application/json")
        ] {
            XCTAssertEqual(try parse(body, type: type)?.durationMs, 8000)
            XCTAssertEqual(try parse(body, type: type, durationMs: 9000)?.durationMs, 9000)
        }
    }

    func testJSONArrayAndEveryContainerKey() throws {
        let array = #"[{"text":" One \n line ","start":10,"end":20},{"text":"Second","start":30,"end":40}]"#
        for body in [array] + ["segments", "transcripts", "captions"].map({ "{\"\($0)\":\(array)}" }) {
            let timeline = try XCTUnwrap(parse(body))
            XCTAssertEqual(timeline.segments.map(\.id), ["transcript-episode-雪-json-0001", "transcript-episode-雪-json-0002"])
            XCTAssertEqual(timeline.segments.map(\.text), ["One line", "Second"])
            XCTAssertEqual(timeline.segments.map(\.startMs), [10, 30])
            XCTAssertEqual(timeline.segments.map(\.endMs), [20, 40])
        }
    }

    func testJSONAcceptedTextStartEndAndDurationKeys() throws {
        for textKey in ["text", "body", "caption"] {
            for startKey in ["start", "startTime", "start_ms", "offset"] {
                for endKey in ["end", "endTime", "end_ms"] {
                    let body = "[{\"\(textKey)\":\"Words\",\"\(startKey)\":100,\"\(endKey)\":300}]"
                    let segment = try XCTUnwrap(parse(body)?.segments.first)
                    XCTAssertEqual(segment.text, "Words")
                    XCTAssertEqual(segment.startMs, 100, body)
                    XCTAssertEqual(segment.endMs, 300, body)
                }
                for durationKey in ["duration", "durationMs", "duration_ms"] {
                    let body = "[{\"\(textKey)\":\"Words\",\"\(startKey)\":100,\"\(durationKey)\":250}]"
                    XCTAssertEqual(try parse(body)?.segments.first?.endMs, 350, body)
                }
            }
        }
    }

    func testJSONNumericUnitsAndStringTimes() throws {
        // Fractions avoid the platform-dependent NSNumber bridge of values like 12.0.
        for (value, expected) in [("12", 12), ("1.5", 1500), ("9999.5", 9_999_500), ("10000.5", 10001), ("\"1.5\"", 1500), ("\"10000\"", 10000), ("\"01:02,500\"", 62500)] {
            let body = "[{\"text\":\"Words\",\"start\":\(value)}]"
            XCTAssertEqual(try parse(body)?.segments.first?.startMs, expected, body)
        }
    }

    func testJSONTextOnlyIDNormalizationAndEndTime() throws {
        for duration in [nil, -5, 0, 500] as [Int?] {
            let timeline = try XCTUnwrap(parse(#"{"text":"  Only\ntext  "}"#, durationMs: duration))
            XCTAssertEqual(timeline.segments.first?.id, "transcript-episode-雪-json-0001")
            XCTAssertEqual(timeline.segments.first?.text, "Only text")
            XCTAssertEqual(timeline.segments.first?.startMs, 0)
            XCTAssertEqual(timeline.segments.first?.endMs, max(1, duration ?? 1))
            XCTAssertEqual(timeline.durationMs, duration ?? 1)
        }
    }

    func testPlainTextIDNormalizationAndEndTime() throws {
        for duration in [nil, -5, 0, 500] as [Int?] {
            let timeline = try XCTUnwrap(parse("  Plain\n\t words  ", type: "text/plain", durationMs: duration))
            XCTAssertEqual(timeline.segments.first?.id, "transcript-episode-雪-plain-0001")
            XCTAssertEqual(timeline.segments.first?.text, "Plain words")
            XCTAssertEqual(timeline.segments.first?.startMs, 0)
            XCTAssertEqual(timeline.segments.first?.endMs, max(1, duration ?? 1))
            XCTAssertEqual(timeline.durationMs, duration ?? 1)
        }
    }

    func testHTMLStrippingPreservesExistingReplacements() throws {
        let html = "<SCRIPT>hidden</SCRIPT><style>hidden</style><video>hidden</video><source src='x'><p>Hello <b>world</b></p><br><h2>Next</h2>"
        XCTAssertEqual(HTMLTextStripping.stripHTML(html), "    \nHello  world \n\n\nNext\n")
        XCTAssertEqual(try parse(html, type: "text/html")?.segments.first?.text, "Hello world Next")
    }

    func testAppDiscoveryDiagnosticsRemainByteIdentical() throws {
        let source = try TestInputs.text(.appSources, "Gate1AppModel.swift")
        let start = try XCTUnwrap(source.range(of: "    func scheduleSourceTranscriptImportIfAvailable("))
        let end = try XCTUnwrap(source.range(of: "    private static func fetchTranscriptLink(", range: start.upperBound..<source.endIndex))
        let scheduler = String(source[start.lowerBound..<end.lowerBound])
        for literal in [
            #"diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "no_links""#,
            #"diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "scheduled:\(sortedLinks.count)""#,
            #"lastFailure = "empty:\(link.type)""#,
            #"self.finishDiscoveredSourceTranscript(timeline, itemId: itemId, linkType: link.type)"#,
            #"self.markSourceTranscriptUnavailable(itemId: itemId, lastFailure: lastFailure)"#
        ] {
            XCTAssertTrue(scheduler.contains(literal), literal)
        }
        // The attached and unavailable values are written by the labelled main-actor finishes (#2512).
        let finishes = try TestInputs.text(.appSources, "Gate1AppModel+TranscriptionRecovery.swift")
        for literal in [
            #"diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "attached:\(linkType)""#,
            #"diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "unavailable:\(lastFailure)""#
        ] {
            XCTAssertTrue(finishes.contains(literal), literal)
        }
    }

    func testEmptyBodiesProduceNoTranscript() throws {
        for (body, type) in [("", "text/plain"), (" \n\t", "text/plain"), ("<p> </p>", "text/html"), ("", "application/json"), ("[]", "application/json"), (#"{"text":" "}"#, "application/json"), (#"[{"text":" "}]"#, "application/json")] {
            XCTAssertNil(try parse(body, type: type), body)
        }
        XCTAssertEqual(try parse("", type: "text/vtt")?.segments.count, 0)
    }
}
