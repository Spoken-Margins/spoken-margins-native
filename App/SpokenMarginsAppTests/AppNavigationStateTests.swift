import XCTest
@testable import SpokenMarginsApp

final class AppNavigationStateTests: XCTestCase {
    func testEachRootRetainsAnIndependentNavigationPath() {
        var navigation = AppNavigationState()

        navigation.push(.item("library-item"), recordingIsLocked: false)
        navigation.select(.sources, recordingIsLocked: false)
        navigation.push(.item("source-item"), recordingIsLocked: false)
        navigation.select(.margins, recordingIsLocked: false)
        navigation.push(.marginDetail("margin-1"), recordingIsLocked: false)

        XCTAssertEqual(navigation.selectedRoot, .margins)
        XCTAssertEqual(navigation.paths[.library], [.item("library-item")])
        XCTAssertEqual(navigation.paths[.sources], [.item("source-item")])
        XCTAssertEqual(navigation.paths[.margins], [.marginDetail("margin-1")])
    }

    func testExplicitRootPushDoesNotChangeTheSelectedRoot() {
        var navigation = AppNavigationState()
        navigation.select(.sources, recordingIsLocked: false)

        navigation.push(.settings, in: .library, recordingIsLocked: false)

        XCTAssertEqual(navigation.selectedRoot, .sources)
        XCTAssertEqual(navigation.paths[.library], [.settings])
        XCTAssertEqual(navigation.paths[.sources], [])
    }

    func testRecordingLockRejectsRootPathAndTaskMutations() {
        var navigation = AppNavigationState()
        navigation.push(.item("current-item"), recordingIsLocked: false)
        navigation.present(.nowPlaying, recordingIsLocked: false)
        let lockedState = navigation

        navigation.select(.sources, recordingIsLocked: true)
        navigation.push(.item("other-item"), recordingIsLocked: true)
        navigation.push(.marginDetail("other-margin"), in: .margins, recordingIsLocked: true)
        navigation.present(.settings, recordingIsLocked: true)
        navigation.dismissTask(recordingIsLocked: true)

        XCTAssertEqual(navigation, lockedState)
    }

    func testTaskCanBeDismissedAfterRecordingUnlocks() {
        var navigation = AppNavigationState()
        navigation.present(.nowPlaying, recordingIsLocked: false)

        navigation.dismissTask(recordingIsLocked: false)

        XCTAssertNil(navigation.taskRoute)
    }
}
