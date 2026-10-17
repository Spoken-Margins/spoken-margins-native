import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// Pulling down on Following reads the followed feeds and waits for them (#1438). The toolbar button starts a
/// refresh and returns at once; a pull-down gesture's spinner lasts as long as its async closure runs, so it must
/// not return before the refresh has landed.
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
}
