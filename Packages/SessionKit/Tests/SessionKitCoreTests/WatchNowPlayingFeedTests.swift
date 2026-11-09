import XCTest
@testable import SessionKit

final class WatchNowPlayingFeedTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        item: String? = "ep-1", status: PlaybackStatus = .playing, title: String? = "Episode one", mediaMs: Int? = 60_000, rate: Double = 1
    ) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.itemId = item
        snapshot.status = status
        snapshot.title = title
        snapshot.currentMediaTimeMs = mediaMs
        snapshot.playbackRate = rate
        return snapshot
    }

    func testALoadedItemIsPublishedAndAnIdleOrFailedPlayerIsNot() {
        for status in [PlaybackStatus.starting, .playing, .paused, .recording] {
            XCTAssertNotNil(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: status), at: t0), "\(status)")
        }
        for status in [PlaybackStatus.idle, .failed] {
            XCTAssertNil(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: status), at: t0), "\(status)")
        }
        XCTAssertNil(WatchNowPlayingFeed.nowPlaying(from: snapshot(item: nil), at: t0))
        XCTAssertNil(WatchNowPlayingFeed.nowPlaying(from: snapshot(item: "  \n"), at: t0))
    }

    func testPlayingAndStartingReadAsPlayingAndPausedAndRecordingDoNot() throws {
        XCTAssertTrue(try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .playing), at: t0)).isPlaying)
        XCTAssertTrue(try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .starting), at: t0)).isPlaying)
        XCTAssertFalse(try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .paused), at: t0)).isPlaying)
        XCTAssertFalse(try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .recording), at: t0)).isPlaying)
    }

    func testTitlesAndPositionsFromOddSnapshotsAreCleaned() throws {
        let blank = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(title: " \n "), at: t0))
        XCTAssertEqual(blank.title, WatchNowPlayingFeed.untitled)
        let missing = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(title: nil, mediaMs: nil), at: t0))
        XCTAssertEqual(missing.title, WatchNowPlayingFeed.untitled)
        XCTAssertEqual(missing.positionMs, 0, "an article read aloud has no media time")
        XCTAssertEqual(missing.rate, 0, "so its position does not move on")
        let negative = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: -5), at: t0))
        XCTAssertEqual(negative.positionMs, 0)
        let long = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(title: String(repeating: "é", count: 500)), at: t0))
        XCTAssertEqual(long.title.count, WatchNowPlayingFeed.maxTitleLength)
        let padded = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(title: "  Hello  "), at: t0))
        XCTAssertEqual(padded.title, "Hello")
        for bad in [0, -1, Double.nan, .infinity] {
            let rate = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(rate: bad), at: t0)).rate
            XCTAssertEqual(rate, 1, "rate \(bad)")
        }
        XCTAssertEqual(try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(rate: 1.5), at: t0)).rate, 1.5)
    }

    func testSteadyPlaybackNeverPublishesAgain() throws {
        let first = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: 60_000), at: t0))
        for seconds in stride(from: 1, through: 600, by: 7) {
            let next = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(
                from: snapshot(mediaMs: 60_000 + seconds * 1_000), at: t0.addingTimeInterval(TimeInterval(seconds))
            ))
            XCTAssertFalse(WatchNowPlayingFeed.shouldPublish(previous: first, next: next), "after \(seconds) s")
        }
    }

    /// The audit of #3524: narrated text has no media time, and its position used to be predicted forward from 0 while the
    /// real value stayed 0, so the board was sent again about every 5 s for as long as it played.
    func testNarratedTextWithNoMediaTimeNeverPublishesAgain() throws {
        let first = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: nil), at: t0))
        for seconds in stride(from: 1, through: 600, by: 3) {
            let next = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: nil), at: t0.addingTimeInterval(TimeInterval(seconds))))
            XCTAssertFalse(WatchNowPlayingFeed.shouldPublish(previous: first, next: next), "after \(seconds) s")
        }
        XCTAssertEqual(first.position(at: t0.addingTimeInterval(600)), 0, "the Watch does not count it up from 0")
        let paused = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .paused, mediaMs: nil), at: t0.addingTimeInterval(5)))
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: paused), "a pause is still news")
    }

    func testAtTwiceTheRateTheWatchPredictsAtTwiceTheRate() throws {
        let first = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: 0, rate: 2), at: t0))
        let later = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: 120_000, rate: 2), at: t0.addingTimeInterval(60)))
        XCTAssertFalse(WatchNowPlayingFeed.shouldPublish(previous: first, next: later))
    }

    func testASeekOrSkipOrStallPublishesButNoiseDoesNot() throws {
        let first = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: 60_000), at: t0))
        func after(_ seconds: TimeInterval, media: Int) throws -> WatchNowPlaying {
            try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(mediaMs: media), at: t0.addingTimeInterval(seconds)))
        }
        XCTAssertFalse(WatchNowPlayingFeed.shouldPublish(previous: first, next: try after(10, media: 74_000)), "4 s of drift")
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try after(10, media: 76_000)), "6 s ahead")
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try after(10, media: 64_000)), "a stall: 6 s behind")
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try after(2, media: 90_000)), "skip forward")
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try after(2, media: 30_000)), "skip back")
    }

    func testPausedItemPublishesWhenItsPositionMoves() throws {
        let paused = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .paused, mediaMs: 60_000), at: t0))
        let still = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .paused, mediaMs: 60_000), at: t0.addingTimeInterval(300)))
        XCTAssertFalse(WatchNowPlayingFeed.shouldPublish(previous: paused, next: still), "a paused item does not move on")
        let skipped = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(status: .paused, mediaMs: 75_000), at: t0.addingTimeInterval(300)))
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: paused, next: skipped))
    }

    func testAChangeOfItemTitlePlayStateRateOrLoadingPublishes() throws {
        let first = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(), at: t0))
        let at = t0.addingTimeInterval(1)
        func next(_ snapshot: SessionSnapshot) throws -> WatchNowPlaying? { WatchNowPlayingFeed.nowPlaying(from: snapshot, at: at) }
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try next(snapshot(item: "ep-2", mediaMs: 61_000))))
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try next(snapshot(title: "Renamed", mediaMs: 61_000))))
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try next(snapshot(status: .paused, mediaMs: 61_000))))
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try next(snapshot(mediaMs: 61_000, rate: 1.25))))
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: first, next: try next(snapshot(status: .idle))), "the item went away")
        XCTAssertTrue(WatchNowPlayingFeed.shouldPublish(previous: nil, next: first), "the first item")
        XCTAssertFalse(WatchNowPlayingFeed.shouldPublish(previous: nil, next: nil))
    }

    func testEachTransportMapsToTheCommandOfTheSameName() {
        XCTAssertEqual(WatchTransport.allCases.map(\.compactCommand), [.play, .pause, .skipBack, .skipForward])
        for transport in WatchTransport.allCases {
            XCTAssertEqual(transport.compactCommand.rawValue, transport.rawValue)
        }
    }

    func testOnlyAFreshTransportEnvelopeYieldsACommand() {
        let sent = WatchEnvelope(seq: 1, sentAt: t0, clock: nil, message: .transport(.pause))
        XCTAssertEqual(sent.transportToRun(now: t0.addingTimeInterval(2)), .pause)
        XCTAssertNil(sent.transportToRun(now: t0.addingTimeInterval(11)), "stale")
        let other = WatchEnvelope(seq: 2, sentAt: t0, clock: nil, message: .hello(holding: []))
        XCTAssertNil(other.transportToRun(now: t0), "not a transport message")
    }

    func testABoardCarriesTheItemWithoutChangingTheSession() throws {
        let session = WatchSessionInfo(id: "s", kind: .other, title: "Morning", owner: .phone, startedAt: t0)
        let board = WatchBoard(running: session, phoneTime: t0)
        let playing = try XCTUnwrap(WatchNowPlayingFeed.nowPlaying(from: snapshot(), at: t0))
        let with = board.with(nowPlaying: playing)
        XCTAssertEqual(with.nowPlaying, playing)
        XCTAssertEqual(with.running, session)
        XCTAssertNil(with.with(nowPlaying: nil).nowPlaying)
    }
}
