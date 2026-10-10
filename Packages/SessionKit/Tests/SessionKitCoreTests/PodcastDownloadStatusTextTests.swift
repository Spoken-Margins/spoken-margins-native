import Foundation
import SessionKit
import XCTest

final class PodcastDownloadStatusTextTests: XCTestCase {
    private func record(
        state: PodcastDownloadState,
        written: Int64 = 0,
        expected: Int64? = nil
    ) -> PodcastDownloadRecord {
        PodcastDownloadRecord(id: "download-episode", itemId: "episode", remoteURL: "https://example.com/audio",
                              state: state, bytesWritten: written, expectedBytes: expected)
    }

    private func mb(_ bytes: Int64) -> String { "\(bytes / 1_000_000) MB" }

    func testADownloadShowsItsPercentAndSizeAsItMoves() {
        let size: Int64 = 107_000_000
        let started = record(state: .downloading, written: 0, expected: size)
        let partway = record(state: .downloading, written: 45_000_000, expected: size)
        XCTAssertEqual(PodcastDownloadStatusText.downloading(started, byteString: mb), "Downloading 0% of 107 MB")
        XCTAssertEqual(PodcastDownloadStatusText.downloading(partway, byteString: mb), "Downloading 42% of 107 MB")
        XCTAssertEqual(PodcastDownloadStatusText.buttonTitle(partway), "Downloading 42%")
    }

    func testTheSizeIsNotInventedBeforeItIsKnown() {
        let unknown = record(state: .downloading, written: 0, expected: nil)
        XCTAssertEqual(PodcastDownloadStatusText.downloading(unknown, byteString: mb), "Downloading…")
        XCTAssertEqual(PodcastDownloadStatusText.buttonTitle(unknown), "Downloading…")
    }

    func testAlmostDoneNeverReadsOneHundredPercent() {
        let size: Int64 = 107_000_000
        let nearly = record(state: .downloading, written: size - 1, expected: size)
        XCTAssertEqual(PodcastDownloadStatusText.downloading(nearly, byteString: mb), "Downloading 99% of 107 MB")
        let allArrived = record(state: .downloading, written: size, expected: size)
        XCTAssertEqual(PodcastDownloadStatusText.downloading(allArrived, byteString: mb), "Finishing the download…")
        XCTAssertEqual(PodcastDownloadStatusText.buttonTitle(allArrived), "Downloading…")
    }

    func testAFinishedDownloadSaysSoWithItsSize() {
        let saved = record(state: .availableOffline, written: 107_000_000, expected: 107_000_000)
        XCTAssertEqual(PodcastDownloadStatusText.downloaded(saved, byteString: mb), "Downloaded, 107 MB")
    }

    func testAFinishedDownloadWithoutASizeStillSaysDownloaded() {
        XCTAssertEqual(PodcastDownloadStatusText.downloaded(record(state: .availableOffline)), "Downloaded")
        let onlyExpected = record(state: .availableOffline, written: 0, expected: 8_000_000)
        XCTAssertEqual(PodcastDownloadStatusText.downloaded(onlyExpected, byteString: mb), "Downloaded, 8 MB")
    }

    func testTheDefaultSizeWordingIsAFileSize() {
        let text = PodcastDownloadStatusText.fileSize(107_000_000)
        XCTAssertTrue(text.contains("MB"), text)
        XCTAssertTrue(text.contains("107"), text)
    }
}
