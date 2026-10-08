import XCTest
@testable import SessionKit

/// What a Library row says about listening offline (#976). The tables are written out by hand; the first
/// test moved here from the app's presentation tests.
final class LibraryOfflineStateTests: XCTestCase {
    func testPodcastDownloadStateDrivesTruthfulLibraryOfflinePresentation() {
        XCTAssertEqual(
            LibraryOfflineStateFilter.forItem(preparedState: nil, mediaSourceType: .remoteStream, podcastDownloadState: .availableOffline),
            .readyOffline
        )
        XCTAssertEqual(
            LibraryOfflineStateFilter.forItem(preparedState: nil, mediaSourceType: .remoteStream, podcastDownloadState: .downloading),
            .preparing
        )
        XCTAssertEqual(
            LibraryOfflineStateFilter.forItem(preparedState: nil, mediaSourceType: .remoteStream, podcastDownloadState: .streamingOnly),
            .onlineOnly
        )
    }

    func testEveryPodcastDownloadStateHasItsOwnAnswer() {
        let table: [(PodcastDownloadState, LibraryOfflineStateFilter)] = [
            (.availableOffline, .readyOffline),
            (.downloading, .preparing),
            (.waitingForWiFi, .preparing),
            (.failed, .needsRepreparation),
            (.evicted, .needsRepreparation),
            (.streamingOnly, .onlineOnly)
        ]
        XCTAssertEqual(table.count, 6, "a new download state needs a row here")
        for (download, expected) in table {
            XCTAssertEqual(
                LibraryOfflineStateFilter.forItem(preparedState: nil, mediaSourceType: nil, podcastDownloadState: download),
                expected, "\(download)"
            )
        }
    }

    func testADownloadStateBeatsThePreparedAudioState() {
        XCTAssertEqual(
            LibraryOfflineStateFilter.forItem(preparedState: .readyOffline, mediaSourceType: .nativeMediaFile, podcastDownloadState: .streamingOnly),
            .onlineOnly
        )
        XCTAssertEqual(
            LibraryOfflineStateFilter.forItem(preparedState: .notPrepared, mediaSourceType: .remoteStream, podcastDownloadState: .availableOffline),
            .readyOffline
        )
    }

    func testEveryPreparedAudioStateHasItsOwnAnswer() {
        let table: [(PreparedAudioState, LibraryOfflineStateFilter)] = [
            (.preparing, .preparing),
            (.pausedForThermal, .preparing),
            (.readyOffline, .readyOffline),
            (.needsRepreparation, .needsRepreparation),
            (.failed, .needsRepreparation),
            (.stopped, .needsRepreparation),
            (.notPrepared, .onlineOnly)
        ]
        XCTAssertEqual(table.count, 7, "a new prepared state needs a row here")
        for (prepared, expected) in table {
            XCTAssertEqual(
                LibraryOfflineStateFilter.forItem(preparedState: prepared, mediaSourceType: .generatedTTSPrerendered, podcastDownloadState: nil),
                expected, "\(prepared)"
            )
        }
    }

    func testAnItemWithNoOtherStateIsReadyOfflineOnlyWhenItIsANativeMediaFile() {
        let table: [(AudioSourceType?, LibraryOfflineStateFilter)] = [
            (.nativeMediaFile, .readyOffline),
            (.remoteStream, .onlineOnly),
            (.browserOwnedMedia, .onlineOnly),
            (.generatedTTSRealtime, .onlineOnly),
            (.generatedTTSPrerendered, .onlineOnly),
            (nil, .onlineOnly)
        ]
        for (source, expected) in table {
            XCTAssertEqual(
                LibraryOfflineStateFilter.forItem(preparedState: nil, mediaSourceType: source, podcastDownloadState: nil),
                expected, "\(String(describing: source))"
            )
        }
    }

    func testTheAnswerIsNeverTheAllFilter() {
        for prepared in [nil, .notPrepared, .preparing, .readyOffline, .failed] as [PreparedAudioState?] {
            for download in [nil, .downloading, .streamingOnly] as [PodcastDownloadState?] {
                XCTAssertNotEqual(
                    LibraryOfflineStateFilter.forItem(preparedState: prepared, mediaSourceType: nil, podcastDownloadState: download),
                    .all
                )
            }
        }
    }
}
