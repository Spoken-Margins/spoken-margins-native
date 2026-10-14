import Foundation
import XCTest
@testable import SessionKit

/// #790: what a car lists and sends. The phone owns playback; these tests hold the car to the phone's own
/// snapshot, so a connection never starts anything and a stale pick never plays the wrong item.
final class CarPlayAdapterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(
        itemId: String? = nil, status: PlaybackStatus = .idle, mediaMs: Int? = nil,
        commands: [CompactControlCommand] = [.play, .pause, .togglePlayPause, .skipBack, .skipForward, .beginInterjection]
    ) -> CompactControlSnapshot {
        CompactControlSnapshot(
            sessionId: itemId.map { "session-\($0)" }, itemId: itemId, targetType: nil, targetId: nil,
            title: itemId.map { "Title \($0)" }, chapterTitle: itemId == nil ? nil : "Chapter 2",
            status: status, phase: .itemPlayback, progressPercent: 40, currentPlaybackProgressPercent: 40,
            sourceProgressPercent: 40, currentMediaTimeMs: mediaMs, currentPlaybackDurationMs: mediaMs.map { $0 * 3 },
            playbackRate: 1.25, isRecording: false, pendingAiJobCount: 0, pendingAiJobKind: nil,
            pendingAiJobStatus: nil, lastUserTurnType: nil, exposedCommands: commands, compactSurfaceReady: true,
            surfaceProfileId: "test"
        )
    }

    private func entry(_ id: String, played: TimeInterval? = nil, percent: Int = 0) -> CarPlayLibraryEntry {
        CarPlayLibraryEntry(
            id: id, title: "Title \(id)", kind: .audio, progressPercent: percent,
            lastPlayedAt: played.map { t0.addingTimeInterval($0) }
        )
    }

    // MARK: Library

    func testOnlyPlayableItemsBecomeEntries() {
        var audio = Item(id: "a", title: "Episode", mediaType: "transcript_backed_media", text: nil, externalReference: nil, status: "ready",
                         media: ItemMedia(sourceType: .remoteStream, url: "https://x/e.mp3"))
        audio.showTitle = "The Show"
        var article = Item(id: "b", title: " Article ", mediaType: "text", text: "Body.", externalReference: nil, status: "ready")
        article.author = "Ann"
        var deleted = article
        deleted.id = "c"
        deleted.deletedAt = t0
        var empty = article
        empty.id = "d"
        empty.text = "  \n"
        let video = Item(id: "e", title: "Video", mediaType: "browser_owned_media", text: "Transcript", externalReference: nil, status: "ready",
                         media: ItemMedia(sourceType: .browserOwnedMedia, url: "https://x/v"))
        var untitled = article
        untitled.id = "f"
        untitled.title = "  "
        var failed = article
        failed.id = "g"
        failed.status = "failed"
        let noFile = Item(id: "h", title: "No file", mediaType: "transcript_backed_media", text: nil, externalReference: nil, status: "ready",
                          media: ItemMedia(sourceType: .remoteStream, url: " "))

        let entries = [audio, article, deleted, empty, video, untitled, failed, noFile].compactMap { CarPlayLibraryEntry(item: $0) }

        XCTAssertEqual(entries.map(\.id), ["a", "b"])
        XCTAssertEqual(entries[0].kind, .audio)
        XCTAssertEqual(entries[0].subtitle, "The Show")
        XCTAssertEqual(entries[1].title, "Article")
        XCTAssertEqual(entries[1].subtitle, "Ann")
        XCTAssertEqual(entries[1].kind, .text)
    }

    func testBrowseListPutsCurrentThenRecentThenUnstartedThenFinished() {
        let library = [
            entry("unstarted-1"), entry("done", played: 50, percent: 100), entry("old", played: 10, percent: 30),
            entry("current", played: 5, percent: 10), entry("recent", played: 90, percent: 60), entry("unstarted-2"),
        ]

        let ids = CarPlayBrowseList.entries(from: library, currentItemId: "current").map(\.id)

        XCTAssertEqual(ids, ["current", "recent", "old", "unstarted-1", "unstarted-2", "done"])
    }

    func testBrowseListIsCappedAndHasNoRepeats() {
        let library = (0..<60).map { entry("item-\($0 % 40)") }

        let ids = CarPlayBrowseList.entries(from: library, currentItemId: nil).map(\.id)

        XCTAssertEqual(ids.count, CarPlayBrowseList.maximumEntries)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, "item-0")
        XCTAssertTrue(CarPlayBrowseList.entries(from: [], currentItemId: "x").isEmpty)
    }

    // MARK: Now playing

    func testNowPlayingReflectsThePhonesItemAndPosition() {
        let playing = CarPlayNowPlaying(snapshot: snapshot(itemId: "ep", status: .playing, mediaMs: 123_000))

        XCTAssertEqual(playing.itemId, "ep")
        XCTAssertEqual(playing.title, "Title ep")
        XCTAssertEqual(playing.chapterTitle, "Chapter 2")
        XCTAssertTrue(playing.isPlaying)
        XCTAssertEqual(playing.positionMs, 123_000)
        XCTAssertEqual(playing.durationMs, 369_000)
        XCTAssertEqual(playing.playbackRate, 1.25)
        XCTAssertEqual(playing.supportedCommands, [.play, .pause, .togglePlayPause, .skipBack, .skipForward],
                       "a car gets no recording or follow-up commands")
        XCTAssertFalse(CarPlayNowPlaying(snapshot: snapshot(itemId: "ep", status: .paused, mediaMs: 5)).isPlaying)
    }

    func testNowPlayingWithNothingLoadedOffersNothing() {
        let idle = CarPlayNowPlaying(snapshot: snapshot())

        XCTAssertNil(idle.itemId)
        XCTAssertFalse(idle.isPlaying)
        XCTAssertTrue(idle.supportedCommands.isEmpty)
        XCTAssertNil(idle.positionMs)
    }

    func testNowPlayingOffersOnlyWhatThePhoneOffers() {
        let state = CarPlayNowPlaying(snapshot: snapshot(itemId: "t", status: .playing, commands: [.pause, .skipForward]))

        XCTAssertEqual(state.supportedCommands, [.pause, .skipForward])
    }

    // MARK: Connecting

    func testConnectingNeverStartsPlaybackAndReflectsWhatIsPlaying() {
        var car = CarPlayConnection()

        let whilePlaying = car.connect(snapshot: snapshot(itemId: "ep", status: .playing, mediaMs: 60_000))
        XCTAssertTrue(car.isConnected)
        XCTAssertTrue(whilePlaying.isPlaying, "a reconnect mid-playback shows it playing, with no command sent")
        XCTAssertEqual(whilePlaying.positionMs, 60_000)

        let whilePaused = car.connect(snapshot: snapshot(itemId: "ep", status: .paused, mediaMs: 61_000))
        XCTAssertFalse(whilePaused.isPlaying)
        let whileIdle = car.connect(snapshot: snapshot())
        XCTAssertNil(whileIdle.itemId)
        XCTAssertFalse(whileIdle.isPlaying, "connecting to an idle phone leaves it idle")
        XCTAssertTrue(whileIdle.supportedCommands.isEmpty)
    }

    func testNothingIsDecidedWhileDisconnected() {
        var car = CarPlayConnection()
        XCTAssertEqual(car.decide(.play, snapshot: snapshot(itemId: "ep", status: .paused), now: t0), .ignore(.notConnected))
        XCTAssertEqual(car.decide(selecting: "ep", library: [entry("ep")], snapshot: snapshot(), now: t0), .ignore(.notConnected))

        _ = car.connect(snapshot: snapshot())
        car.disconnect()
        XCTAssertEqual(car.decide(.pause, snapshot: snapshot(itemId: "ep", status: .playing), now: t0), .ignore(.notConnected))
    }

    // MARK: Commands

    func testCommandsGoThroughThePhonesOwnControls() {
        var car = CarPlayConnection()
        _ = car.connect(snapshot: snapshot(itemId: "ep", status: .playing))

        XCTAssertEqual(car.decide(.pause, snapshot: snapshot(itemId: "ep", status: .playing), now: t0), .dispatch(.pause))
        XCTAssertEqual(car.decide(.skipForward, snapshot: snapshot(itemId: "ep", status: .playing), now: t0), .dispatch(.skipForward))
        XCTAssertEqual(car.decide(.skipBack, snapshot: snapshot(itemId: "ep", status: .playing), now: t0), .dispatch(.skipBack))
        XCTAssertEqual(car.decide(.togglePlayPause, snapshot: snapshot(itemId: "ep", status: .playing), now: t0), .dispatch(.togglePlayPause))
    }

    func testAnUnofferedCommandOrAnEmptyPhoneIsIgnored() {
        var car = CarPlayConnection()
        _ = car.connect(snapshot: snapshot())

        XCTAssertEqual(car.decide(.play, snapshot: snapshot(), now: t0), .ignore(.unavailable), "nothing is loaded")
        let noSkip = snapshot(itemId: "t", status: .playing, commands: [.play, .pause])
        XCTAssertEqual(car.decide(.skipForward, snapshot: noSkip, now: t0), .ignore(.unavailable))
    }

    func testDuplicateCommandsInsideTheRepeatWindowRunOnce() {
        var car = CarPlayConnection()
        let playing = snapshot(itemId: "ep", status: .playing)
        _ = car.connect(snapshot: playing)

        XCTAssertEqual(car.decide(.skipForward, snapshot: playing, now: t0), .dispatch(.skipForward))
        XCTAssertEqual(car.decide(.skipForward, snapshot: playing, now: t0.addingTimeInterval(0.3)), .ignore(.duplicate))
        XCTAssertEqual(car.decide(.skipBack, snapshot: playing, now: t0.addingTimeInterval(0.4)), .dispatch(.skipBack),
                       "a different command is not a repeat")
        XCTAssertEqual(car.decide(.skipForward, snapshot: playing, now: t0.addingTimeInterval(2)), .dispatch(.skipForward),
                       "a deliberate second press after the window runs")
    }

    func testPlayWhilePlayingAndPauseWhilePausedChangeNothing() {
        var car = CarPlayConnection()
        let playing = snapshot(itemId: "ep", status: .playing)
        let paused = snapshot(itemId: "ep", status: .paused)
        _ = car.connect(snapshot: playing)

        XCTAssertEqual(car.decide(.play, snapshot: playing, now: t0), .ignore(.alreadyDone))
        XCTAssertEqual(car.decide(.pause, snapshot: paused, now: t0.addingTimeInterval(5)), .ignore(.alreadyDone))
        XCTAssertEqual(car.decide(.play, snapshot: paused, now: t0.addingTimeInterval(10)), .dispatch(.play))
    }

    func testReconnectingForgetsTheLastCommand() {
        var car = CarPlayConnection()
        let playing = snapshot(itemId: "ep", status: .playing)
        _ = car.connect(snapshot: playing)
        XCTAssertEqual(car.decide(.skipBack, snapshot: playing, now: t0), .dispatch(.skipBack))

        _ = car.connect(snapshot: playing)

        XCTAssertEqual(car.decide(.skipBack, snapshot: playing, now: t0.addingTimeInterval(0.1)), .dispatch(.skipBack))
    }

    // MARK: Picking an item

    func testPickingAnotherItemStartsItThroughThePhonesStartPath() {
        var car = CarPlayConnection()
        let library = [entry("a"), entry("b")]
        _ = car.connect(snapshot: snapshot(itemId: "a", status: .playing))

        XCTAssertEqual(car.decide(selecting: "b", library: library, snapshot: snapshot(itemId: "a", status: .playing), now: t0),
                       .start(itemId: "b"))
        XCTAssertEqual(car.decide(selecting: "a", library: library, snapshot: snapshot(), now: t0.addingTimeInterval(5)),
                       .start(itemId: "a"))
    }

    func testPickingThePlayingItemDoesNothingAndThePausedOneResumes() {
        var car = CarPlayConnection()
        let library = [entry("a")]
        _ = car.connect(snapshot: snapshot(itemId: "a", status: .playing))

        XCTAssertEqual(car.decide(selecting: "a", library: library, snapshot: snapshot(itemId: "a", status: .playing), now: t0),
                       .ignore(.alreadyDone))
        XCTAssertEqual(car.decide(selecting: "a", library: library, snapshot: snapshot(itemId: "a", status: .paused, mediaMs: 9_000),
                                  now: t0.addingTimeInterval(5)),
                       .resumeCurrent, "resumes where it is; it does not restart the item")
    }

    func testAPickOfAnItemThatLeftTheLibraryIsRefused() {
        var car = CarPlayConnection()
        _ = car.connect(snapshot: snapshot())

        let decision = car.decide(selecting: "gone", library: [entry("a")], snapshot: snapshot(), now: t0)

        XCTAssertEqual(decision, .itemGone)
        XCTAssertEqual(car.decide(selecting: "gone", library: [], snapshot: snapshot(), now: t0.addingTimeInterval(5)), .itemGone)
    }

    func testAnUnplayableItemIsNeverInTheLibraryTheCarChecksAgainst() {
        var deleted = Item(id: "x", title: "X", mediaType: "text", text: "Body", externalReference: nil, status: "ready")
        let before = [deleted].compactMap { CarPlayLibraryEntry(item: $0) }
        deleted.deletedAt = t0
        let after = [deleted].compactMap { CarPlayLibraryEntry(item: $0) }
        var car = CarPlayConnection()
        _ = car.connect(snapshot: snapshot())

        XCTAssertEqual(car.decide(selecting: "x", library: before, snapshot: snapshot(), now: t0), .start(itemId: "x"))
        XCTAssertEqual(car.decide(selecting: "x", library: after, snapshot: snapshot(), now: t0.addingTimeInterval(5)), .itemGone,
                       "deleted after the list was drawn")
    }

    func testTheSamePickTwiceInARowStartsOnce() {
        var car = CarPlayConnection()
        let library = [entry("a")]
        _ = car.connect(snapshot: snapshot())

        XCTAssertEqual(car.decide(selecting: "a", library: library, snapshot: snapshot(), now: t0), .start(itemId: "a"))
        XCTAssertEqual(car.decide(selecting: "a", library: library, snapshot: snapshot(), now: t0.addingTimeInterval(0.2)), .ignore(.duplicate))
    }

    func testPlaybackFollowsThePhoneAfterTheLibraryChangesUnderTheCar() {
        var car = CarPlayConnection()
        _ = car.connect(snapshot: snapshot(itemId: "a", status: .playing, mediaMs: 4_000))
        let nowOnPhone = [entry("a"), entry("c")]

        XCTAssertEqual(car.decide(selecting: "b", library: nowOnPhone, snapshot: snapshot(itemId: "a", status: .playing, mediaMs: 4_000), now: t0),
                       .itemGone)
        XCTAssertEqual(car.decide(selecting: "c", library: nowOnPhone, snapshot: snapshot(itemId: "a", status: .playing, mediaMs: 4_000),
                                  now: t0.addingTimeInterval(5)),
                       .start(itemId: "c"))
    }

    func testPickingTheLoadedItemWhileRecordingAMarginDoesNotInterruptIt() {
        var car = CarPlayConnection()
        let recording = snapshot(itemId: "a", status: .recording)
        _ = car.connect(snapshot: recording)

        XCTAssertEqual(car.decide(selecting: "a", library: [entry("a")], snapshot: recording, now: t0), .ignore(.unavailable))
    }

    func testPickingALoadedItemThatFailedOrWentIdleStartsItAgain() {
        var car = CarPlayConnection()
        _ = car.connect(snapshot: snapshot())

        XCTAssertEqual(car.decide(selecting: "a", library: [entry("a")], snapshot: snapshot(itemId: "a", status: .failed), now: t0),
                       .start(itemId: "a"))
        XCTAssertEqual(car.decide(selecting: "a", library: [entry("a")], snapshot: snapshot(itemId: "a", status: .idle), now: t0.addingTimeInterval(5)),
                       .start(itemId: "a"))
    }

    func testAResumingPickAndACarPlayKeyRightAfterItAreOneRequest() {
        var car = CarPlayConnection()
        let paused = snapshot(itemId: "a", status: .paused, mediaMs: 9_000)
        _ = car.connect(snapshot: paused)

        XCTAssertEqual(car.decide(selecting: "a", library: [entry("a")], snapshot: paused, now: t0), .resumeCurrent)
        XCTAssertEqual(car.decide(.play, snapshot: paused, now: t0.addingTimeInterval(0.2)), .ignore(.duplicate))
    }

    func testTheRepeatWindowEndsExactlyAtItsLength() {
        var car = CarPlayConnection()
        let playing = snapshot(itemId: "a", status: .playing)
        _ = car.connect(snapshot: playing)

        XCTAssertEqual(car.decide(.skipBack, snapshot: playing, now: t0), .dispatch(.skipBack))
        XCTAssertEqual(car.decide(.skipBack, snapshot: playing, now: t0.addingTimeInterval(CarPlayConnection.repeatWindow - 0.01)), .ignore(.duplicate))
        XCTAssertEqual(car.decide(.skipBack, snapshot: playing, now: t0.addingTimeInterval(CarPlayConnection.repeatWindow)), .dispatch(.skipBack))
        // A clock that steps backwards is not read as a repeat.
        XCTAssertEqual(car.decide(.skipBack, snapshot: playing, now: t0.addingTimeInterval(-60)), .dispatch(.skipBack))
    }
}
