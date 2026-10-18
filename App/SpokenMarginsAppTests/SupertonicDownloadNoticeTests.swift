import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #1820: the one-time "Supertonic is now a free download" card and its way to Settings › Voices.
@MainActor
final class SupertonicDownloadNoticeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "SupertonicDownloadNoticeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testAJamesListenerWithoutTheDownloadSeesTheCardOnceAcrossLaunches() {
        let store = defaults()
        let first = SupertonicDownloadNotice(defaults: store, modelInstalled: { false })
        first.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: false)
        XCTAssertTrue(first.isPresented)
        XCTAssertTrue(store.bool(forKey: SupertonicDownloadNoticePolicy.seenKey), "recorded when shown, so a quit doesn't bring it back")

        let nextLaunch = SupertonicDownloadNotice(defaults: store, modelInstalled: { false })
        nextLaunch.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: false)
        XCTAssertFalse(nextLaunch.isPresented)
    }

    func testTheCardWaitsBehindAnotherSheetAndForAListenerOnTheIOSVoice() {
        let store = defaults()
        let notice = SupertonicDownloadNotice(defaults: store, modelInstalled: { false })
        notice.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: true)
        notice.presentIfNeeded(savedVoiceIsSupertonic: false, anotherSheetShowing: false)
        XCTAssertFalse(notice.isPresented)
        XCTAssertFalse(store.bool(forKey: SupertonicDownloadNoticePolicy.seenKey))
        notice.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: false)
        XCTAssertTrue(notice.isPresented)
    }

    func testAListenerWhoAlreadyDownloadedSupertonicNeverSeesIt() {
        let store = defaults()
        var installed = true
        let notice = SupertonicDownloadNotice(defaults: store, modelInstalled: { installed })
        notice.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: false)
        XCTAssertFalse(notice.isPresented)
        installed = false  // removed later in Settings › Voices
        notice.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: false)
        XCTAssertFalse(notice.isPresented)
    }

    func testOpenVoicesClosesTheCardAndSettingsOpensVoicesOnce() {
        let notice = SupertonicDownloadNotice(defaults: defaults(), modelInstalled: { false })
        notice.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: false)
        XCTAssertFalse(notice.takeVoicesRequest(), "no request before the button")
        notice.openVoices()
        XCTAssertFalse(notice.isPresented)
        XCTAssertTrue(notice.takeVoicesRequest())
        XCTAssertFalse(notice.takeVoicesRequest(), "a later visit to Settings stays on Settings")
    }
}
