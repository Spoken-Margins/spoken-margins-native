import XCTest
@testable import SessionKit

/// With no signal, a streamed-only episode says it isn't downloaded instead of blaming saved audio (#779).
final class OfflinePlayabilityTests: XCTestCase {
    func testADownloadedEpisodePlaysOfflineAndAStreamedOneNeedsSignal() {
        XCTAssertEqual(OfflinePlayability(.audio(hasSavedAudio: true)), .playsOffline)
        XCTAssertEqual(OfflinePlayability(.audio(hasSavedAudio: false)), .needsSignal)
    }

    func testAFullyPreparedArticlePlaysOffline() {
        XCTAssertEqual(OfflinePlayability(.text(hasStoredText: true, preparedAudio: .complete)), .playsOffline)
    }

    func testAPartlyPreparedArticlePlaysPartlyOfflineWithTheLiveVoice() {
        XCTAssertEqual(OfflinePlayability(.text(hasStoredText: true, preparedAudio: .partial)), .playsPartlyOffline)
        XCTAssertEqual(
            OfflinePlayability(.text(hasStoredText: true, preparedAudio: .none)), .playsPartlyOffline,
            "stored text with nothing prepared still plays offline, all of it in the live voice"
        )
    }

    func testAnItemWithNothingOnThePhoneNeedsSignal() {
        for prepared in [OfflinePlayability.PreparedAudio.none, .partial, .complete] {
            XCTAssertEqual(OfflinePlayability(.text(hasStoredText: false, preparedAudio: prepared)), .needsSignal)
        }
    }

    // MARK: The pre-play check

    func testOfflineAStreamedOnlyEpisodeIsStoppedWithThePlainMessage() {
        XCTAssertEqual(
            OfflinePlayability.episodeStartBlockedMessage(hasSavedAudio: false, isOffline: true),
            "This episode isn't downloaded, and there's no signal."
        )
    }

    func testADownloadedEpisodeStillPlaysOffline() {
        XCTAssertNil(OfflinePlayability.episodeStartBlockedMessage(hasSavedAudio: true, isOffline: true))
    }

    func testWithSignalOrAnUnknownNetworkNothingIsBlocked() {
        XCTAssertNil(OfflinePlayability.episodeStartBlockedMessage(hasSavedAudio: false, isOffline: false))
    }

    // MARK: The stall message

    func testAStalledStreamNeverBlamesSavedAudio() {
        for isOffline in [true, false] {
            let message = OfflinePlayability.episodeStalledMessage(hasSavedAudio: false, isOffline: isOffline)
            XCTAssertFalse(message.contains("Download Again"), message)
            XCTAssertFalse(message.contains("saved audio"), message)
        }
        XCTAssertEqual(
            OfflinePlayability.episodeStalledMessage(hasSavedAudio: false, isOffline: true),
            OfflinePlayability.episodeNotDownloadedMessage
        )
        XCTAssertEqual(
            OfflinePlayability.episodeStalledMessage(hasSavedAudio: false, isOffline: false),
            "Podcast playback did not start. Check your connection, then press Play."
        )
    }

    func testDownloadAgainStaysForASavedFileThatFails() {
        for isOffline in [true, false] {
            XCTAssertEqual(
                OfflinePlayability.episodeStalledMessage(hasSavedAudio: true, isOffline: isOffline),
                "Podcast playback did not start. Use Download Again in More to replace the saved audio, then press Play."
            )
        }
    }
}
