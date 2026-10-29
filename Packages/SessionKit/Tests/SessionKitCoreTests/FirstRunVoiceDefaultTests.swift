import SessionKit
import XCTest

/// #2858: a fresh install starts on Phonon; a saved voice stays; Phonon not yet installed reads in the backup voice
/// and the download waits for the Terms and for Wi-Fi.
final class FirstRunVoiceDefaultTests: XCTestCase {
    func testAFreshInstallOnAPhoneThatFitsStartsOnPhonon() {
        XCTAssertEqual(FirstRunVoiceDefault.migrationChoice(hadSavedSelection: false, phononFitsDevice: true), .phonon)
    }

    func testASavedVoiceStaysJames() {
        XCTAssertEqual(FirstRunVoiceDefault.migrationChoice(hadSavedSelection: true, phononFitsDevice: true), .james)
        XCTAssertEqual(FirstRunVoiceDefault.migrationChoice(hadSavedSelection: true, phononFitsDevice: false), .james)
    }

    func testAFreshInstallBelowPhononsFloorKeepsTheOldDefault() {
        XCTAssertEqual(FirstRunVoiceDefault.migrationChoice(hadSavedSelection: false, phononFitsDevice: false), .james)
    }

    private func action(
        due: Bool = true, terms: Bool = true, choice: ReadingVoiceChoice = .phonon,
        state: VoiceCatalogRowState? = .notInstalled, offered: Bool = true, tried: Bool = false,
        expensive: Bool = false, constrained: Bool = false
    ) -> FirstRunVoiceDefault.DownloadAction {
        FirstRunVoiceDefault.downloadAction(
            isDue: due, termsAccepted: terms, choice: choice, state: state, isOffered: offered,
            triedThisLaunch: tried, isExpensive: expensive, isConstrained: constrained)
    }

    func testTheDownloadStartsOnWiFiOnceTheTermsAreAccepted() {
        XCTAssertEqual(action(), .start)
    }

    func testTheDownloadWaitsForTheTermsAndNeverStartsBeforeThem() {
        XCTAssertEqual(action(terms: false), .none)
    }

    func testTheDownloadWaitsForWiFiOnMobileDataAndInLowDataMode() {
        XCTAssertEqual(action(expensive: true), .waitForWiFi)
        XCTAssertEqual(action(constrained: true), .waitForWiFi)
    }

    func testNothingStartsWhenItIsNotDueIsInstalledIsNotOfferedOrWasTriedThisLaunch() {
        XCTAssertEqual(action(due: false), .none)
        XCTAssertEqual(action(state: .installed(version: "1", byteCount: 10)), .none)
        XCTAssertEqual(action(state: nil), .none)
        XCTAssertEqual(action(offered: false), .none)
        XCTAssertEqual(action(tried: true), .none)
    }

    func testAListenerWhoPickedAnotherVoiceIsNeverDownloadedFor() {
        for choice in ReadingVoiceChoice.allCases where choice != .phonon {
            XCTAssertEqual(action(choice: choice), .none, "\(choice)")
            XCTAssertTrue(FirstRunVoiceDefault.isSettled(choice: choice, state: .notInstalled), "\(choice)")
        }
    }

    func testTheDownloadStaysDueUntilPhononIsInstalled() {
        XCTAssertFalse(FirstRunVoiceDefault.isSettled(choice: .phonon, state: .notInstalled))
        XCTAssertFalse(FirstRunVoiceDefault.isSettled(choice: .phonon, state: nil))
        XCTAssertTrue(FirstRunVoiceDefault.isSettled(choice: .phonon, state: .installed(version: "1", byteCount: 10)))
    }

    func testThePlainLineSaysPhononIsDownloadingAndWhoReadsMeanwhile() {
        let line = FirstRunVoiceDefault.statusLine(choice: .phonon, state: .notInstalled, progress: .downloading(fraction: 0.456))
        XCTAssertEqual(line, "Phonon is downloading (45%). Until it finishes, the app’s backup voice reads to you.")
        XCTAssertEqual(
            FirstRunVoiceDefault.statusLine(choice: .phonon, state: .notInstalled, progress: .downloading(fraction: nil)),
            "Phonon is downloading. Until it finishes, the app’s backup voice reads to you.")
    }

    func testThePlainLineCoversWaitingFailingAndNotStarting() {
        for progress in [FirstRunVoiceDefault.Progress.waitingForWiFi, .failed, .notDownloaded] {
            let line = FirstRunVoiceDefault.statusLine(choice: .phonon, state: .notInstalled, progress: progress)
            XCTAssertTrue(line?.contains("backup voice reads to you") == true, "\(progress)")
        }
    }

    func testNoLineWhenPhononIsInstalledOrNotTheChoice() {
        XCTAssertNil(FirstRunVoiceDefault.statusLine(choice: .phonon, state: .installed(version: "1", byteCount: 1), progress: .failed))
        XCTAssertNil(FirstRunVoiceDefault.statusLine(choice: .james, state: .notInstalled, progress: .failed))
        XCTAssertNil(FirstRunVoiceDefault.statusLine(choice: .phonon, state: nil, progress: .notDownloaded))
    }
}
