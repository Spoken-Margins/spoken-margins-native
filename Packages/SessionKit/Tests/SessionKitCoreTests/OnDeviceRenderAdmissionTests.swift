import XCTest
@testable import SessionKit

/// #2695: once the bundled voice stands in, nothing renders Supertonic, for the player or for the Library.
final class OnDeviceRenderAdmissionTests: XCTestCase {
    private typealias Live = OnDeviceRenderAdmission.Live

    /// The owner's 10-25 kill: the stand-in took over at a background seam on a `fair` phone, Kitten rendered minutes
    /// ahead, and Supertonic's queue looked free, so a Library Supertonic render ran beside it.
    func testNothingRendersSupertonicOnceTheStandInHoldsInTheBackground() {
        let governor = OnDeviceVoiceGovernor(conditions: { SpeechEngineConditions(thermal: .fair) })
        governor.setAppBackgrounded(true)
        // The phone allows Supertonic again (a background gap, not heat): the stand-in still renders the item.
        XCTAssertEqual(OnDeviceRenderAdmission.liveRenderer(
            chosenAllowed: governor.supertonicRenderingBlock() == nil, standInHolds: true, standInAvailable: true), .standIn)
        // Kitten has rendered far ahead, which used to free Supertonic's renderer for the Library.
        for ahead in [0, 2, 40] {
            XCTAssertFalse(OnDeviceRenderAdmission.libraryMayShareRenderer(Live(
                isPlaying: true, standInHolds: true, isWaiting: false, isFullyRendered: false, chunksAhead: ahead)), "\(ahead) ahead")
        }
        XCTAssertFalse(OnDeviceRenderAdmission.libraryMayShareRenderer(Live(
            isPlaying: true, standInHolds: true, isWaiting: false, isFullyRendered: true, chunksAhead: .max)), "fully rendered")
        // And the Library loop's own gate (#2694) refuses it too.
        var library = LibraryAudioRenderPolicy()
        library.noteListenerEngaged()
        XCTAssertFalse(library.allowsRendering(.init(isPlaybackActive: true, isMedia: false, hasSession: true)))
    }

    func testTheLiveRendererTable() {
        typealias A = OnDeviceRenderAdmission
        XCTAssertEqual(A.liveRenderer(chosenAllowed: true, standInHolds: false, standInAvailable: true), .chosen)
        XCTAssertEqual(A.liveRenderer(chosenAllowed: false, standInHolds: false, standInAvailable: true), .standIn, "heat")
        XCTAssertEqual(A.liveRenderer(chosenAllowed: true, standInHolds: true, standInAvailable: true), .standIn, "no bounce (#1680)")
        XCTAssertEqual(A.liveRenderer(chosenAllowed: false, standInHolds: false, standInAvailable: false), .none, "iOS voice")
        XCTAssertEqual(A.liveRenderer(chosenAllowed: true, standInHolds: true, standInAvailable: false), .chosen)
    }

    func testSupertonicLiveStillYieldsItsRendererAsBefore() {
        func yields(_ live: Live) -> Bool { OnDeviceRenderAdmission.libraryMayShareRenderer(live) }
        XCTAssertTrue(yields(Live(isPlaying: true, standInHolds: false, isWaiting: false, isFullyRendered: false, chunksAhead: 2)))
        XCTAssertFalse(yields(Live(isPlaying: true, standInHolds: false, isWaiting: false, isFullyRendered: false, chunksAhead: 1)))
        XCTAssertTrue(yields(Live(isPlaying: true, standInHolds: false, isWaiting: false, isFullyRendered: true, chunksAhead: 0)))
        XCTAssertFalse(yields(Live(isPlaying: true, standInHolds: false, isWaiting: true, isFullyRendered: true, chunksAhead: 9)))
        XCTAssertTrue(yields(Live(isPlaying: false, standInHolds: true, isWaiting: true, isFullyRendered: false, chunksAhead: 0)), "paused")
    }
}
