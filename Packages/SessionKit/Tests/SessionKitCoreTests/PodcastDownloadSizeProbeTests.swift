import Foundation
import XCTest
@testable import SessionKit

/// #912: the download needed a HEAD answer with a positive Content-Length, so a host that refuses HEAD or
/// leaves the length out could never be downloaded. These are the rules that read the size from whatever
/// the host does answer, and that bound a download whose host never says.
final class PodcastDownloadSizeProbeTests: XCTestCase {
    func testHeadAnnouncesTheSizeOnlyForASuccessfulAnswerWithAPositiveLength() {
        let rows: [(status: Int, length: Int64, expected: Int64?, note: String)] = [
            (200, 8_000, 8_000, "an ordinary HEAD"),
            (206, 8_000, 8_000, "a partial answer still has a length"),
            (302, 8_000, 8_000, "a redirect that wasn't followed still passes, as before"),
            (200, -1, nil, "no Content-Length (unknown length)"),
            (200, 0, nil, "Content-Length: 0 is a host that answers HEAD with nothing"),
            (403, 8_000, nil, "a presigned URL that refuses HEAD"),
            (405, 8_000, nil, "a host that doesn't allow HEAD"),
            (404, 8_000, nil, "a missing file is not a size"),
            (500, 8_000, nil, "a server error is not a size"),
            (200, Int64.min, nil, "a nonsense length"),
        ]
        for row in rows {
            XCTAssertEqual(
                PodcastDownloadSizeProbe.headLength(statusCode: row.status, expectedContentLength: row.length),
                row.expected, row.note
            )
        }
    }

    func testRangeProbeReadsTheTotalFromContentRangeOrFromAHostThatIgnoredTheRange() {
        let rows: [(status: Int, range: String?, length: Int64, expected: Int64?, note: String)] = [
            (206, "bytes 0-0/12345", 1, 12_345, "the ordinary partial answer"),
            (206, "BYTES 0-0/12345", 1, 12_345, "the unit is case-insensitive"),
            (206, " bytes 0-0/12345 ", 1, 12_345, "stray whitespace"),
            (206, "bytes 0-0/*", 1, nil, "a host that doesn't know the total"),
            (206, nil, 1, nil, "a 206 with no Content-Range says nothing"),
            (206, "bytes 0-0/0", 1, nil, "a zero total"),
            (206, "bytes 5-9/4", 5, nil, "a range outside its own total"),
            (206, "bytes 9-5/20", 1, nil, "a range that runs backwards"),
            (206, "bytes */12345", 1, nil, "the unsatisfied form carries no range"),
            (206, "items 0-0/12345", 1, nil, "another range unit"),
            (206, "bytes 0-0/abc", 1, nil, "a total that isn't a number"),
            (206, "bytes 0-0/-5", 1, nil, "a negative total"),
            (206, "", 1, nil, "an empty header"),
            (200, nil, 12_345, 12_345, "a host that ignored the range sends the whole file's length"),
            (200, nil, -1, nil, "ignored the range and announced nothing"),
            (200, nil, 0, nil, "ignored the range and sent a zero length"),
            (403, "bytes 0-0/12345", 12_345, nil, "a refusal is not a size, even with a header"),
            (404, nil, 12_345, nil, "a missing file"),
            (416, "bytes */12345", 0, nil, "range not satisfiable"),
            (302, nil, 12_345, nil, "an unfollowed redirect"),
        ]
        for row in rows {
            XCTAssertEqual(
                PodcastDownloadSizeProbe.rangeProbeLength(
                    statusCode: row.status, contentRange: row.range, expectedContentLength: row.length
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

    func testAReservationIsTheAnnouncedSizeOrAnUnannouncedBoundThatNeverExceedsTheBudget() {
        let bound = PodcastDownloadSizeProbe.unannouncedLimitBytes
        let rows: [(announced: Int64?, budget: Int64, expected: Int64, note: String)] = [
            (8_000, 5_000_000_000, 8_000, "an announced size is reserved as announced"),
            (0, 5_000_000_000, 0, "an announced zero is not turned into a guess"),
            (-3, 5_000_000_000, 0, "a negative size reserves nothing"),
            (nil, 5_000_000_000, bound, "an unannounced size reserves the bound"),
            (nil, 1_000_000_000, bound, "a 1 GB budget still has room for the bound"),
            (nil, 200_000_000, 200_000_000, "a small budget caps the reservation"),
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

    func testOnlyADownloadWhoseHostNeverAnnouncesATotalIsCutOffAtTheBound() {
        let bound = PodcastDownloadSizeProbe.unannouncedLimitBytes
        let rows: [(written: Int64, expectedTotal: Int64, cutOff: Bool, note: String)] = [
            (bound, -1, false, "exactly at the bound is still allowed"),
            (bound + 1, -1, true, "one byte past the bound with no announced total"),
            (bound + 1, 0, true, "a zero total is no announcement"),
            (bound + 1, bound * 3, false, "an announced total is held to the budget at commit instead"),
            (1_000, -1, false, "a small download with no total"),
            (0, -1, false, "nothing written yet"),
        ]
        for row in rows {
            XCTAssertEqual(
                PodcastDownloadSizeProbe.exceedsUnannouncedLimit(
                    totalBytesWritten: row.written, totalBytesExpectedToWrite: row.expectedTotal
                ),
                row.cutOff, row.note
            )
        }
    }
}
