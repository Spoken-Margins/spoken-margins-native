import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// Every test starts from a listener who has already answered the first-use voice Terms (#3329).
///
/// On a fresh simulator nobody has answered them, so `startItem` on a text item waits on the Terms sheet and no session
/// starts. Tests that start playback passed anyway when an earlier test, in the same simulator, had answered them
/// (`declineCurrentTerms()` leaves the choice in `UserDefaults.standard`), and failed when their class ran alone:
/// #286 (`LocalAudioListeningPackageTests`) and the lane run on PR #3322 (`SpokenMarginsPackageImportCoordinatorTests`).
/// About 57 tests answer the Terms by hand for this reason and nothing made a new test do it. This observer does it in one
/// place, so a test's result no longer depends on which test ran before it.
///
/// What it sets is exactly what `declineCurrentTerms()` leaves: the iOS system voice, no voice waiting on the Terms.
/// A test about the Terms or the voice choice builds its own starting state and restores the defaults afterwards, as
/// it does today; `SpokenMarginsTermsTests` sets all of its keys itself. Terms already accepted are left alone.
///
/// XCTest finds it through `OpenDescriptorGuard`, the bundle's principal class, which installs it when the bundle loads.
@objc(SMTermsAnsweredBeforeEachTest)
final class TermsAnsweredBeforeEachTest: NSObject, XCTestObservation, @unchecked Sendable {
    nonisolated(unsafe) static private(set) var shared: TermsAnsweredBeforeEachTest?

    static func install() {
        guard shared == nil else { return }
        let observer = TermsAnsweredBeforeEachTest()
        shared = observer
        XCTestObservationCenter.shared.addTestObserver(observer)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        Self.answerTheTerms(in: .standard)
    }

    /// The defaults a listener has after choosing the iOS voice on the Terms sheet. Nothing changes once the Terms
    /// are accepted: that listener never sees the sheet, whatever voice they use.
    static func answerTheTerms(in defaults: UserDefaults) {
        guard !SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults) else { return }
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.system.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("systemImmediate", forKey: "ttsMode")
        defaults.removeObject(forKey: Gate1AppModel.supertonicVoicePendingTermsKey)
    }
}

/// The observer's own checks, and the end-to-end one: a class that does nothing about the Terms can start playback.
final class TermsAnsweredBeforeEachTestTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "TermsAnsweredBeforeEachTestTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAFreshSimulatorGetsTheAnsweredStateThatDecliningLeaves() throws {
        let defaults = try makeDefaults()
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("supertonic", forKey: "ttsMode")
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: Gate1AppModel.supertonicVoicePendingTermsKey)

        TermsAnsweredBeforeEachTest.answerTheTerms(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "ttsVoiceSelection"), AppTTSVoiceSelection.system.rawValue)
        XCTAssertEqual(defaults.string(forKey: "ttsMode"), "systemImmediate")
        XCTAssertTrue(defaults.bool(forKey: "supertonicTTSMigrationV1"))
        XCTAssertNil(defaults.object(forKey: Gate1AppModel.supertonicVoicePendingTermsKey))
        XCTAssertFalse(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults), "answering is not accepting")
    }

    func testAcceptedTermsAndTheirVoiceAreLeftAlone() throws {
        let defaults = try makeDefaults()
        SpokenMarginsTerms.recordAcceptance(in: defaults)
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("supertonic", forKey: "ttsMode")

        TermsAnsweredBeforeEachTest.answerTheTerms(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "ttsVoiceSelection"), AppTTSVoiceSelection.james.rawValue)
        XCTAssertEqual(defaults.string(forKey: "ttsMode"), "supertonic")
    }

    func testTheObserverIsInstalledByTheBundle() throws {
        XCTAssertNotNil(TermsAnsweredBeforeEachTest.shared, "OpenDescriptorGuard.init must call TermsAnsweredBeforeEachTest.install()")
    }

    /// The class of bug: a model that starts a text item and never answers the Terms. Before this observer it started
    /// no session on a fresh simulator and passed only after an earlier test had answered them.
    func testAModelThatNeverAnswersTheTermsStartsPlaying() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        defer { model.pause() }

        model.startItem(id: "item-pill")

        XCTAssertFalse(model.isTermsOfUsePresented, "the Terms sheet is up: \(model.diagnostics["termsGate"] ?? "none")")
        XCTAssertNotNil(model.snapshot.sessionId)
    }
}
