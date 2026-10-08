import Foundation
import XCTest
@testable import SessionKit

/// #912: the download needed a HEAD answer with a positive Content-Length, so a host that refuses HEAD or
/// leaves the length out could never be downloaded. These are the rules that read the size from whatever
/// the host does answer, that fail fast for a host that refuses everything, and that bound a download
/// whose host never says.
final class PodcastDownloadSizeProbeTests: XCTestCase {
    func testHeadAnnouncesTheSizeOnlyForASuccessfulAnswerWithAPositiveLength() {
        let rows: [(status: Int, length: Int64, header: String?, expected: Int64?, note: String)] = [
            (200, 8_000, nil, 8_000, "an ordinary HEAD"),
            (206, 8_000, nil, 8_000, "a partial answer still has a length"),
            (302, 8_000, nil, 8_000, "a redirect that wasn't followed still passes, as before"),
            (200, -1, nil, nil, "no Content-Length (unknown length)"),
            (200, 0, nil, nil, "Content-Length: 0 is a host that answers HEAD with nothing"),
            (403, 8_000, nil, nil, "a presigned URL that refuses HEAD"),
            (405, 8_000, nil, nil, "a host that doesn't allow HEAD"),
            (404, 8_000, nil, nil, "a missing file is not a size"),
            (500, 8_000, nil, nil, "a server error is not a size"),
            (200, Int64.min, nil, nil, "a nonsense length"),
            (200, -1, "8000", 8_000, "the header stands in when the loader's figure is unknown"),
            (200, -1, " 8000 ", 8_000, "stray whitespace in the header"),
            (200, 0, "8000", 8_000, "the header stands in for a zero figure too"),
            (200, 5_000, "9000", 5_000, "the loader's figure wins over the header"),
            (200, -1, "0", nil, "a zero header"),
            (200, -1, "-4", nil, "a negative header"),
            (200, -1, "abc", nil, "a header that isn't a number"),
            (200, -1, "", nil, "an empty header"),
            (403, -1, "8000", nil, "a refusal is not a size, whatever the header says"),
        ]
        for row in rows {
            XCTAssertEqual(
                PodcastDownloadSizeProbe.headLength(
                    statusCode: row.status, expectedContentLength: row.length, contentLengthHeader: row.header
                ),
                row.expected, row.note
            )
        }
    }

    func testRangeProbeReadsTheTotalFromContentRangeOrFromAHostThatIgnoredTheRange() {
        typealias Probe = PodcastDownloadSizeProbe.RangeProbe
        let rows: [(status: Int, range: String?, length: Int64, header: String?, expected: Probe, note: String)] = [
            (206, "bytes 0-0/12345", 1, nil, .length(12_345), "the ordinary partial answer"),
            (206, "BYTES 0-0/12345", 1, nil, .length(12_345), "the unit is case-insensitive"),
            (206, " bytes 0-0/12345 ", 1, nil, .length(12_345), "stray whitespace"),
            (206, "bytes 0-0/*", 1, nil, .unannounced, "a host that doesn't know the total"),
            (206, nil, 1, nil, .unannounced, "a 206 with no Content-Range says nothing"),
            (206, "bytes 0-0/0", 1, nil, .unannounced, "a zero total"),
            (206, "bytes 5-9/4", 5, nil, .unannounced, "a range outside its own total"),
            (206, "bytes 9-5/20", 1, nil, .unannounced, "a range that runs backwards"),
            (206, "bytes */12345", 1, nil, .unannounced, "the unsatisfied form carries no range"),
            (206, "items 0-0/12345", 1, nil, .unannounced, "another range unit"),
            (206, "bytes 0-0/abc", 1, nil, .unannounced, "a total that isn't a number"),
            (206, "bytes 0-0/-5", 1, nil, .unannounced, "a negative total"),
            (206, "", 1, nil, .unannounced, "an empty header"),
            (206, nil, 1, "12345", .unannounced, "a 206's Content-Length is the slice's, never the total"),
            (200, nil, 12_345, nil, .length(12_345), "a host that ignored the range sends the whole file's length"),
            (200, nil, -1, "12345", .length(12_345), "the header stands in when the loader's figure is unknown"),
            (200, nil, -1, nil, .unannounced, "ignored the range and announced nothing"),
            (200, nil, 0, nil, .unannounced, "ignored the range and sent a zero length"),
            (416, "bytes */12345", 0, nil, .unannounced, "range not satisfiable says nothing about whether GET works"),
            (302, nil, 12_345, nil, .unannounced, "an unfollowed redirect"),
            (204, nil, -1, nil, .unannounced, "another success"),
            (403, "bytes 0-0/12345", 12_345, nil, .refused(statusCode: 403), "a refusal is not a size, even with a header"),
            (404, nil, 12_345, nil, .refused(statusCode: 404), "a missing file"),
            (410, nil, -1, nil, .refused(statusCode: 410), "an expired episode"),
            (401, nil, -1, nil, .refused(statusCode: 401), "a login wall"),
            (500, nil, -1, nil, .refused(statusCode: 500), "a server error"),
            (503, nil, -1, nil, .refused(statusCode: 503), "a host that is down"),
            (100, nil, -1, nil, .refused(statusCode: 100), "an interim status is not an answer"),
        ]
        for row in rows {
            XCTAssertEqual(
                PodcastDownloadSizeProbe.rangeProbe(
                    statusCode: row.status, contentRange: row.range,
                    expectedContentLength: row.length, contentLengthHeader: row.header
                ),
                row.expected, row.note
            )
        }
    }

    func testContentRangeTotalKeepsLargeAndEdgeTotals() {
        XCTAssertEqual(PodcastDownloadSizeProbe.contentRangeTotal("bytes 0-0/1"), 1, "a one-byte file")
        XCTAssertEqual(PodcastDownloadSizeProbe.contentRangeTotal("bytes 0-499/1234"), 1_234)
        XCTAssertEqual(
            PodcastDownloadSizeProbe.contentRangeTotal("bytes 0-0/9000000000"), 9_000_000_000,
            "a total past 32 bits"
        )
        XCTAssertNil(PodcastDownloadSizeProbe.contentRangeTotal("bytes 0-0/99999999999999999999"), "overflows Int64")
    }

    func testAReservationIsTheAnnouncedSizeOrAModestGuessThatNeverExceedsTheBudget() {
        let guess = PodcastDownloadSizeProbe.unannouncedReservationBytes
        XCTAssertLessThan(guess, PodcastDownloadSizeProbe.unannouncedLimitBytes,
                          "the reservation is modest; the hard bound is the cut-off")
        let rows: [(announced: Int64?, budget: Int64, expected: Int64, note: String)] = [
            (8_000, 5_000_000_000, 8_000, "an announced size is reserved as announced"),
            (600_000_000, 5_000_000_000, 600_000_000, "an announced size past the guess is still as announced"),
            (0, 5_000_000_000, 0, "an announced zero is not turned into a guess"),
            (-3, 5_000_000_000, 0, "a negative size reserves nothing"),
            (nil, 5_000_000_000, guess, "an unannounced size reserves the modest guess"),
            (nil, 1_000_000_000, guess, "a 1 GB budget has room for the guess"),
            (nil, 60_000_000, 60_000_000, "a small budget caps the reservation"),
            (nil, 0, 0, "no budget, no reservation"),
            (nil, -5, 0, "a negative budget reserves nothing"),
        ]
        for row in rows {
            XCTAssertEqual(
                PodcastDownloadSizeProbe.reservationBytes(announcedLength: row.announced, budgetLimitBytes: row.budget),
                row.expected, row.note
            )
        }
    }

    func testOnlyADownloadNobodyAnnouncedASizeForIsCutOffAtTheBound() {
        let bound = PodcastDownloadSizeProbe.unannouncedLimitBytes
        let rows: [(written: Int64, recorded: Int64?, total: Int64, cutOff: Bool, note: String)] = [
            (bound, nil, -1, false, "exactly at the bound is still allowed"),
            (bound + 1, nil, -1, true, "one byte past the bound with no announced size anywhere"),
            (bound + 1, nil, 0, true, "a zero total is no announcement"),
            (bound + 1, 0, -1, true, "a recorded zero is no announcement"),
            (bound + 1, nil, bound * 3, false, "the download announces its total: held to the budget at commit"),
            (bound + 1, 600_000_000, -1, false, "the preflight announced a size and the download is chunked"),
            (bound + 1, 600_000_000, bound * 3, false, "announced both ways"),
            (1_000, nil, -1, false, "a small download with no size"),
            (0, nil, -1, false, "nothing written yet"),
        ]
        for row in rows {
            XCTAssertEqual(
                PodcastDownloadSizeProbe.exceedsUnannouncedLimit(
                    totalBytesWritten: row.written, recordedExpectedBytes: row.recorded,
                    totalBytesExpectedToWrite: row.total
                ),
                row.cutOff, row.note
            )
        }
    }
}
