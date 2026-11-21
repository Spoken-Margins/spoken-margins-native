import XCTest
@testable import SessionKit

/// #3788: a tap made before its start is possible is kept, runs by itself when it can, and is dropped when the friend
/// leaves, the item changes, the Margins are heard, or the download fails.
@MainActor
final class FriendArrivalKeeperTests: XCTestCase {
    private typealias Start = FriendArrivalStart

    private final class Screen {
        var itemId = "item"
        var canStart = false
        var failed = false
        var firstMargin: Start.FirstMarginAudio? = .recording(onPhone: true)
        var hasMargins = true
        var place = "idle"
        var started: [Start.Choice] = []
        var announced: [String] = []
        var changes = 0

        var facts: FriendArrivalKeeper.Facts {
            .init(itemId: itemId,
                  start: Start(episodeCanStart: canStart, episodeFailed: failed, firstMargin: firstMargin),
                  hasMargins: hasMargins, place: place)
        }
    }

    private func keeper(_ screen: Screen, limit: Duration = .seconds(30)) -> FriendArrivalKeeper {
        let keeper = FriendArrivalKeeper(announce: { screen.announced.append($0) }, pollInterval: .milliseconds(5), limit: limit)
        keeper.onChange = { screen.changes += 1 }
        return keeper
    }

    private func tap(_ choice: Start.Choice, _ keeper: FriendArrivalKeeper, _ screen: Screen) {
        keeper.tap(choice, facts: { screen.facts }, start: { screen.started.append($0) })
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(250)) }

    func testAReadyTapRunsAtOnceWithNoLine() {
        let screen = Screen()
        screen.canStart = true
        let keeper = keeper(screen)
        tap(.play, keeper, screen)
        XCTAssertEqual(screen.started, [.play])
        XCTAssertNil(keeper.line)
        XCTAssertTrue(screen.announced.isEmpty)
    }

    func testAnEarlyTapShowsTheLineIsAnnouncedOnceAndRunsWhenReady() async {
        let screen = Screen()
        let keeper = keeper(screen)
        tap(.play, keeper, screen)
        tap(.play, keeper, screen)
        XCTAssertEqual(keeper.line, FriendArrivalStart.waitingLine)
        XCTAssertEqual(screen.announced, [FriendArrivalStart.waitingLine], "announced once")
        XCTAssertTrue(screen.started.isEmpty)
        await settle()
        XCTAssertTrue(screen.started.isEmpty, "still waiting")
        screen.canStart = true
        await settle()
        XCTAssertEqual(screen.started, [.play], "ran once, with no second tap")
        XCTAssertNil(keeper.line)
    }

    func testTheOtherButtonSwitchesWhatIsKept() async {
        let screen = Screen()
        screen.firstMargin = .reading(isReady: false)
        screen.canStart = false
        let keeper = keeper(screen)
        tap(.play, keeper, screen)
        tap(.skip, keeper, screen)
        XCTAssertEqual(keeper.keptChoice, .skip)
        XCTAssertEqual(screen.announced.count, 1)
        screen.firstMargin = .reading(isReady: true)
        await settle()
        XCTAssertEqual(screen.started, [.skip], "Skip started, Play did not")
    }

    func testLeavingTheScreenCancelsAndNothingStartsLater() async {
        let screen = Screen()
        let keeper = keeper(screen)
        tap(.play, keeper, screen)
        keeper.cancel()
        XCTAssertNil(keeper.line)
        screen.canStart = true
        await settle()
        XCTAssertTrue(screen.started.isEmpty)
    }

    func testAnotherItemOrNoMarginsLeftDropsTheTap() async {
        for change in [{ (s: Screen) in s.itemId = "other" }, { (s: Screen) in s.hasMargins = false }] {
            let screen = Screen()
            screen.firstMargin = .reading(isReady: false)
            let keeper = keeper(screen)
            tap(.skip, keeper, screen)
            XCTAssertNotNil(keeper.line)
            change(screen)
            screen.canStart = true
            screen.firstMargin = .recording(onPhone: true)
            await settle()
            XCTAssertTrue(screen.started.isEmpty)
            XCTAssertNil(keeper.line)
        }
    }

    func testAFailedDownloadEndsTheWaitAndPlayStillRunsTheOrdinaryPath() async {
        let screen = Screen()
        let keeper = keeper(screen)
        tap(.play, keeper, screen)
        screen.failed = true
        await settle()
        XCTAssertTrue(screen.started.isEmpty, "the line goes; the failure card says why")
        XCTAssertNil(keeper.line)
        // Tapping Play on a failed episode is not swallowed: today's path runs and reports it.
        tap(.play, keeper, screen)
        XCTAssertEqual(screen.started, [.play])
    }

    func testAnUnavailableFirstMarginIsNotHeldSoTheReviewSaysWhy() {
        let screen = Screen()
        screen.firstMargin = .unavailable
        let keeper = keeper(screen)
        tap(.skip, keeper, screen)
        XCTAssertEqual(screen.started, [.skip])
        XCTAssertNil(keeper.line)
    }

    func testPlayOnAFailedEpisodeRunsEvenWhileSkipIsKept() async {
        let screen = Screen()
        screen.firstMargin = .reading(isReady: false)
        let keeper = keeper(screen)
        tap(.skip, keeper, screen)
        screen.failed = true
        tap(.play, keeper, screen)
        XCTAssertEqual(screen.started, [.play], "Play is not a dead button")
        XCTAssertEqual(keeper.keptChoice, .skip, "Skip is still kept")
    }

    func testStartingSomethingElseMeanwhileDropsTheTap() async {
        let screen = Screen()
        screen.firstMargin = .reading(isReady: false)
        let keeper = keeper(screen)
        tap(.skip, keeper, screen)
        screen.place = "playing elsewhere"
        screen.firstMargin = .reading(isReady: true)
        await settle()
        XCTAssertTrue(screen.started.isEmpty)
        XCTAssertNil(keeper.line)
    }

    func testSwitchingTheKeptButtonRestartsTheCount() async {
        let screen = Screen()
        screen.firstMargin = .reading(isReady: false)
        let keeper = keeper(screen, limit: .milliseconds(400))
        tap(.skip, keeper, screen)
        try? await Task.sleep(for: .milliseconds(250))
        screen.canStart = false
        tap(.play, keeper, screen)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(screen.started.isEmpty, "the count began again with the other button")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(screen.started, [.play])
    }

    func testAWaitThatNeverEndsStartsAnywayAtTheLimit() async {
        let screen = Screen()
        screen.firstMargin = .reading(isReady: false)
        let keeper = keeper(screen, limit: .milliseconds(30))
        tap(.skip, keeper, screen)
        await settle()
        XCTAssertEqual(screen.started, [.skip])
        XCTAssertNil(keeper.line)
    }

    func testTheViewIsToldWhenTheLineComesAndGoes() async {
        let screen = Screen()
        let keeper = keeper(screen)
        tap(.play, keeper, screen)
        XCTAssertEqual(screen.changes, 1)
        screen.canStart = true
        await settle()
        XCTAssertEqual(screen.changes, 2)
    }
}
