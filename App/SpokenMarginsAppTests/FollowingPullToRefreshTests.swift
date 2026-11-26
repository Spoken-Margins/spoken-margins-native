import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// Pulling down on Following reads the followed feeds and waits for them (#1438). It is Following's only manual refresh
/// since #4955. A pull-down gesture's spinner lasts as long as its async closure runs, so it must not return before the
/// refresh has landed, including a refresh that was already running when the pull came.
@MainActor
final class FollowingPullToRefreshTests: XCTestCase {
    func testThePullReturnsOnlyAfterTheFollowedFeedsAreRefreshed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("following.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        // Let the model's launch refresh finish, so the pull under test is not swallowed by it.
        let launchDeadline = Date().addingTimeInterval(10)
        while model.diagnostics["followedSourceCount"] == nil || model.isRefreshingFollowedSources, Date() < launchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.diagnostics["followedSourceCount"], "the launch refresh landed before the pull")
        // No feeds are followed, so the refresh fetches nothing; it still records the count when it lands.
        model.diagnostics["followedSourceCount"] = nil

        await model.pullToRefreshFollowing()

        XCTAssertFalse(model.isRefreshingFollowedSources, "the pull waited for the refresh to end")
        XCTAssertEqual(model.diagnostics["followedSourceCount"], "0", "the refresh had landed when the pull returned")
    }

    /// #4955: a pull made while a pass runs (the one opening the tab starts) waits for that pass to end, rather than
    /// returning at once and snapping its spinner shut. Without the wait the pull returns at once and `waitingCount`
    /// never reaches 1.
    func testAPullDuringARunningPassWaitsForThatPass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("following.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.resetAndSeed()
        try await pollUntil(timeout: .seconds(10)) {
            model.diagnostics["followedSourceCount"] != nil && !model.isRefreshingFollowedSources
        }
        XCTAssertFalse(model.isRefreshingFollowedSources, "the launch refresh ended before the test's own pass")

        // Stand in for a running pass: hold the gate and raise the flag, as `refreshFollowedSourcePasses` does.
        XCTAssertTrue(model.followedSourceRefreshGate.request(forced: true))
        model.isRefreshingFollowedSources = true

        let box = Returned()
        let pull = Task { @MainActor in
            await model.pullToRefreshFollowing()
            box.returned = true
        }
        try await pollUntil(timeout: .seconds(5)) { model.followedSourcePassEnd.waitingCount == 1 }
        XCTAssertEqual(model.followedSourcePassEnd.waitingCount, 1, "the refused pull is waiting for the pass")
        XCTAssertFalse(box.returned, "the pull returned while the pass still ran")

        // End the pass, with no await in between, as the pass's own `defer` does. The pull's request asked for one more
        // round, so the gate frees only on a later `finishPass()`.
        while model.followedSourceRefreshGate.finishPass() != nil {}
        model.isRefreshingFollowedSources = false
        model.followedSourcePassEnd.passEnded()

        try await pollUntil(timeout: .seconds(5)) { box.returned }
        XCTAssertTrue(box.returned, "the pull still waiting after the pass ended")
        await pull.value
    }

    @MainActor private final class Returned { var returned = false }
}
