import Foundation
import SessionKit
import XCTest

/// The row rules behind a podcast download (#318), moved out of the app's coordinator so the ones that keep a
/// listener's saved episode safe are checked on the host. Each test names the rule; the coordinator's own
/// app-hosted tests still drive them through real files, a real store and the URLSession delegate.
final class PodcastDownloadRecordTransitionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func row(
        state: PodcastDownloadState = .downloading, path: String? = nil, written: Int64 = 0, expected: Int64? = nil,
        failure: String? = nil, url: String = "http://example.com/a.mp3"
    ) -> PodcastDownloadRecord {
        PodcastDownloadRecord(
            id: "d1", itemId: "item", remoteURL: url, localRelativePath: path, state: state,
            bytesWritten: written, expectedBytes: expected, lastPlayedAt: t0, updatedAt: t0, failureReason: failure,
            retryCount: 2)
    }

    func testStartingADownloadResetsProgressButKeepsTheSavedFileOfAReplacement() {
        let saved = row(state: .failed, path: "old.mp3", written: 900, expected: 1_000, failure: "boom")
        let started = saved.startingDownload(remoteURL: "https://example.com/a.mp3")
        XCTAssertEqual(started.state, .downloading)
        XCTAssertEqual(started.remoteURL, "https://example.com/a.mp3")
        XCTAssertEqual(started.bytesWritten, 0)
        XCTAssertNil(started.expectedBytes)
        XCTAssertNil(started.failureReason)
        XCTAssertEqual(started.localRelativePath, "old.mp3", "the old episode stays playable while its replacement downloads")
        XCTAssertEqual(started.retryCount, 2)
        XCTAssertEqual(started.lastPlayedAt, t0)
        XCTAssertEqual(started.updatedAt, t0, "stamping is the caller's")
    }

    func testAdoptingAFileMakesTheRowAvailableWithItsExactSize() {
        let downloading = row(state: .downloading, path: "old.mp3", written: 10, expected: nil, failure: "earlier")
        let adopted = downloading.adoptingFile(named: "gen.mp3", size: 4_096)
        XCTAssertEqual(adopted.state, .availableOffline)
        XCTAssertEqual(adopted.localRelativePath, "gen.mp3")
        XCTAssertEqual(adopted.bytesWritten, 4_096)
        XCTAssertEqual(adopted.expectedBytes, 4_096)
        XCTAssertNil(adopted.failureReason)
        XCTAssertEqual(adopted.lastPlayedAt, t0, "a touch by playback in the meantime survives")
        XCTAssertEqual(adopted.remoteURL, downloading.remoteURL)
    }

    /// The row a finished download is stated on top of may be one playback saved while the download committed: only
    /// the file fields change, so the newer play time and retry count are kept.
    func testAdoptingOnTopOfANewerRowKeepsWhatThatRowAlreadySaid() {
        var newer = row(state: .downloading)
        newer.lastPlayedAt = Date(timeIntervalSince1970: 5_000)
        newer.retryCount = 7
        let adopted = newer.adoptingFile(named: "gen.mp3", size: 1)
        XCTAssertEqual(adopted.lastPlayedAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(adopted.retryCount, 7)
    }

    func testEvictingForgetsTheFileAndSizes() {
        let evicted = row(state: .availableOffline, path: "a.mp3", written: 5, expected: 5, failure: "x").evicted()
        XCTAssertEqual(evicted.state, .evicted)
        XCTAssertNil(evicted.localRelativePath)
        XCTAssertEqual(evicted.bytesWritten, 0)
        XCTAssertNil(evicted.expectedBytes)
        XCTAssertNil(evicted.failureReason)
    }

    /// A replacement download that fails must not cost the listener the episode they already have.
    func testAFailedReplacementKeepsTheSavedAudioAvailableAndSaysSo() {
        let failed = row(state: .downloading, path: "old.mp3", written: 3, expected: 9)
            .failing(reason: "The connection was lost.", retainedFileSize: 1_234)
        XCTAssertEqual(failed.state, .availableOffline)
        XCTAssertEqual(failed.bytesWritten, 1_234)
        XCTAssertEqual(failed.expectedBytes, 1_234)
        XCTAssertEqual(failed.localRelativePath, "old.mp3")
        XCTAssertEqual(failed.failureReason,
                       "Replacement download failed; saved audio is still available. The connection was lost.")
    }

    func testAFirstDownloadThatFailsIsFailedWithItsOwnReason() {
        let failed = row(state: .downloading, written: 3, expected: 9).failing(reason: "The host refused.", retainedFileSize: nil)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failureReason, "The host refused.")
        XCTAssertNil(failed.localRelativePath)
        XCTAssertEqual(failed.bytesWritten, 3, "a first failure leaves the byte count as it was")
    }

    /// A table of saved-file sizes against what the row recorded: empty files are never accepted, a row that recorded
    /// no size accepts any non-empty file, and a recorded size must match exactly (a cut-short file does not).
    func testASavedFileIsAcceptedOnlyWhenItIsNotEmptyAndMatchesWhatWasRecorded() {
        let table: [(written: Int64, fileSize: Int, accepts: Bool)] = [
            (0, 0, false), (0, 1, true), (0, 9_999_999, true),
            (100, 0, false), (100, 99, false), (100, 100, true), (100, 101, false),
            (Int64(Int32.max) + 1, Int.max, false),
        ]
        for entry in table {
            XCTAssertEqual(
                row(state: .availableOffline, path: "a.mp3", written: entry.written).acceptsSavedFile(ofSize: entry.fileSize),
                entry.accepts, "written \(entry.written), file \(entry.fileSize)")
        }
        if Int.bitWidth == 64 {
            let big: Int64 = 5_000_000_000
            XCTAssertTrue(row(path: "a.mp3", written: big).acceptsSavedFile(ofSize: Int(big)), "a file over 4 GB")
        }
    }

    func testAMissingOrCutShortFileFailsTheRowAndForgetsTheFile() {
        let found = row(state: .availableOffline, path: "a.mp3", written: 100, expected: 100).foundMissingFile()
        XCTAssertEqual(found.state, .failed)
        XCTAssertNil(found.localRelativePath)
        XCTAssertEqual(found.failureReason, "Downloaded file is missing or incomplete. Download it again.")
        XCTAssertEqual(found.failureReason, PodcastDownloadRecord.missingFileReason)
    }

    // MARK: Interruptions

    private func interruption(
        userInitiated: Bool, exceeded: Bool = false, transport: PodcastNetworkTransport, error: String = "The network connection was lost."
    ) -> PodcastDownloadRecord.Interruption {
        row(state: .downloading, written: 50, expected: 100, failure: "old")
            .interrupted(userInitiated: userInitiated, exceededUnannouncedLimit: exceeded, transport: transport, reason: error)
    }

    func testAnEpisodeThatPassedItsUnannouncedBoundFailsWithThatReasonOnEveryNetworkAndForEveryStarter() {
        for transport in [PodcastNetworkTransport.wifi, .cellular, .unavailable, .other] {
            for userInitiated in [true, false] {
                XCTAssertEqual(
                    interruption(userInitiated: userInitiated, exceeded: true, transport: transport),
                    .failed(reason: PodcastDownloadSizeProbe.unannouncedLimitMessage),
                    "\(transport) \(userInitiated)")
            }
        }
    }

    func testADownloadTheListenerDidNotStartWaitsOffWiFiInsteadOfFailing() {
        for (transport, expected) in [
            (PodcastNetworkTransport.cellular, PodcastDownloadState.streamingOnly),
            (.unavailable, .waitingForWiFi), (.other, .waitingForWiFi),
        ] {
            guard case .waiting(let waiting) = interruption(userInitiated: false, transport: transport) else {
                return XCTFail("\(transport) should wait")
            }
            XCTAssertEqual(waiting.state, expected, "\(transport)")
            XCTAssertNil(waiting.failureReason, "the old failure text is cleared")
            XCTAssertEqual(waiting.bytesWritten, 50)
        }
    }

    func testAListenerStartedDownloadFailsWithTheErrorWhateverTheNetwork() {
        for transport in [PodcastNetworkTransport.wifi, .cellular, .unavailable, .other] {
            XCTAssertEqual(interruption(userInitiated: true, transport: transport), .failed(reason: "The network connection was lost."),
                           "\(transport)")
        }
    }

    func testAnAutomaticDownloadThatFailsOnWiFiFailsWithTheError() {
        XCTAssertEqual(interruption(userInitiated: false, transport: .wifi), .failed(reason: "The network connection was lost."))
    }

    // MARK: Launch

    private func restore(
        _ record: PodcastDownloadRecord, retained: Int64? = nil, fileExists: Bool = true
    ) -> (restoration: PodcastDownloadRecord.Restoration, asked: [String]) {
        var asked: [String] = []
        let restoration = record.restoredAtLaunch(
            retainedFileSize: { asked.append("retained"); return retained },
            fileExists: { asked.append("exists"); return fileExists })
        return (restoration, asked)
    }

    /// A kill during a replacement left a `failed` row beside a saved file: the listener keeps the episode.
    func testALaunchFindingAFailedReplacementBesideASavedFileMakesTheAudioAvailable() {
        let (result, _) = restore(row(state: .failed, path: "old.mp3", written: 1, failure: "x"), retained: 2_048)
        XCTAssertEqual(result.record.state, .availableOffline)
        XCTAssertEqual(result.record.bytesWritten, 2_048)
        XCTAssertEqual(result.record.expectedBytes, 2_048)
        XCTAssertEqual(result.record.failureReason, "Replacement download failed; saved audio is still available.")
        XCTAssertTrue(result.localAssetReady)
        XCTAssertEqual(result.writes, [result.record], "written behind, once")
    }

    func testALaunchWithAFailedRowAndNoSavedFileLeavesItFailedAndWritesNothing() {
        let (result, asked) = restore(row(state: .failed, written: 4, failure: "refused"), retained: nil)
        XCTAssertEqual(result.record, row(state: .failed, written: 4, failure: "refused"))
        XCTAssertEqual(result.writes, [])
        XCTAssertFalse(result.localAssetReady)
        XCTAssertEqual(asked, ["retained"], "no file check for a row that isn't available")
    }

    func testALaunchWhoseSavedFileIsGoneFailsTheRowWithTheRetryText() {
        let available = row(state: .availableOffline, path: "a.mp3", written: 10, expected: 10)
        let (result, asked) = restore(available, fileExists: false)
        XCTAssertEqual(result.record.state, .failed)
        XCTAssertNil(result.record.localRelativePath)
        XCTAssertEqual(result.record.failureReason, "Downloaded file is missing. Retry to download it again.")
        XCTAssertFalse(result.localAssetReady)
        XCTAssertEqual(result.writes, [result.record])
        XCTAssertEqual(asked, ["exists"], "an available row never asks for the retained size")
    }

    func testALaunchWithItsFileStillThereChangesNothingAndSaysTheAssetIsReady() {
        let available = row(state: .availableOffline, path: "a.mp3", written: 10, expected: 10)
        let (result, _) = restore(available, fileExists: true)
        XCTAssertEqual(result.record, available)
        XCTAssertEqual(result.writes, [])
        XCTAssertTrue(result.localAssetReady)
    }

    func testAFailedReplacementWhoseFileThenVanishesIsWrittenTwiceInOrder() {
        // The retained size was read, but the existence check says the file is gone by the time it is asked.
        let (result, _) = restore(row(state: .failed, path: "old.mp3"), retained: 5, fileExists: false)
        XCTAssertEqual(result.writes.map(\.state), [.availableOffline, .failed])
        XCTAssertEqual(result.record.state, .failed)
        XCTAssertNil(result.record.localRelativePath)
    }

    func testALaunchTurnsADownloadThatWasCutOffIntoOneWaitingForWiFi() {
        let (result, asked) = restore(row(state: .downloading, written: 7, expected: 70))
        XCTAssertEqual(result.record.state, .waitingForWiFi)
        XCTAssertEqual(result.record.bytesWritten, 7)
        XCTAssertEqual(result.writes, [result.record])
        XCTAssertEqual(asked, [])
    }

    func testALaunchLeavesWaitingStreamingAndEvictedRowsAlone() {
        for state in [PodcastDownloadState.waitingForWiFi, .streamingOnly, .evicted] {
            let stored = row(state: state)
            let (result, asked) = restore(stored)
            XCTAssertEqual(result.record, stored, "\(state)")
            XCTAssertEqual(result.writes, [], "\(state)")
            XCTAssertFalse(result.localAssetReady, "\(state)")
            XCTAssertEqual(asked, [], "\(state)")
        }
    }

    // MARK: Network changes

    func testOnWiFiOnlyRowsThatWaitedStartAnAutomaticDownload() {
        for state in PodcastDownloadState.allCasesForTests {
            let expected: PodcastDownloadRecord.NetworkReaction? =
                (state == .waitingForWiFi || state == .streamingOnly) ? .startAutomaticDownload : nil
            for userInitiated in [true, false] {
                XCTAssertEqual(row(state: state).reaction(toTransport: .wifi, userInitiated: userInitiated), expected,
                               "\(state) \(userInitiated)")
            }
        }
    }

    func testLeavingWiFiPausesAutomaticDownloadsAndLeavesTheListenersOwnRunning() {
        for transport in [PodcastNetworkTransport.cellular, .unavailable, .other] {
            let target: PodcastDownloadState = transport == .cellular ? .streamingOnly : .waitingForWiFi
            for state in PodcastDownloadState.allCasesForTests {
                let paused = state == .downloading || state == .waitingForWiFi
                XCTAssertEqual(row(state: state).reaction(toTransport: transport, userInitiated: false),
                               paused ? .pause(to: target) : nil, "\(state) on \(transport)")
                XCTAssertNil(row(state: state).reaction(toTransport: transport, userInitiated: true),
                             "the listener's own download keeps going: \(state) on \(transport)")
            }
        }
    }
}

private extension PodcastDownloadState {
    /// Every case, spelled out; the exhaustive switch below stops compiling when one is added without a row here.
    static let allCasesForTests: [PodcastDownloadState] = {
        let all: [PodcastDownloadState] = [.waitingForWiFi, .downloading, .availableOffline, .streamingOnly, .failed, .evicted]
        for state in all {
            switch state {
            case .waitingForWiFi, .downloading, .availableOffline, .streamingOnly, .failed, .evicted: break
            }
        }
        return all
    }()
}
