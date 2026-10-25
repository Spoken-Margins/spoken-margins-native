import XCTest
@testable import SessionKit

/// #2694: nothing is rendered in the background while the listener is hearing on-device speech, and not
/// right after a relaunch that restored a speech session either.
final class LibraryAudioPreparationPlaybackTests: XCTestCase {
    private func allows(media: Bool = false, playing: Bool = false, held: Bool = false) -> Bool {
        LibraryAudioPreparationPlayback.allows(isMediaPlayback: media, isPlaybackActive: playing, holdsForRestoredSpeech: held)
    }

    func testAnIdleLibraryMayPrepare() {
        XCTAssertTrue(allows())
    }

    func testSpeechPlayingBlocksPreparationNoMatterHowFarAheadItIs() {
        XCTAssertFalse(allows(playing: true))
    }

    func testARestoredSpeechSessionHoldsPreparationUntilTheListenerActs() {
        XCTAssertFalse(allows(held: true), "paused after a relaunch: the listener is about to resume")
        XCTAssertFalse(allows(playing: true, held: true))
    }

    func testAPodcastNeverHoldsTheLibraryBack() {
        XCTAssertTrue(allows(media: true, playing: true))
        XCTAssertTrue(allows(media: true, held: true))
    }
}
