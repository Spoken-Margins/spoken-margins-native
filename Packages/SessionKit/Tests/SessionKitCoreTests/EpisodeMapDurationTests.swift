import XCTest
@testable import SessionKit

/// #4186: the preparer fingerprints against the file's real length, not a feed's provisional one.
final class EpisodeMapDurationTests: XCTestCase {
    func testTheFilesLengthWinsOverAStoredFeedLengthEitherWay() {
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: 57 * 60_000, storedMs: 60 * 60_000), 57 * 60_000, "feed longer than the file")
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: 66 * 60_000, storedMs: 60 * 60_000), 66 * 60_000, "feed shorter than the file")
    }

    func testTheStoredLengthIsTheFallbackWhenTheFileCannotBeRead() {
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: nil, storedMs: 60_000), 60_000)
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: 0, storedMs: 60_000), 60_000)
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: -1, storedMs: 60_000), 60_000)
    }

    func testNothingKnownIsZeroAsBefore() {
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: nil, storedMs: nil), 0)
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: nil, storedMs: 0), 0)
        XCTAssertEqual(EpisodeMapDuration.choose(fileMs: 0, storedMs: -5), 0)
    }
}
