import XCTest
@testable import DesktopCore

final class DesktopVoiceOnboardingTests: XCTestCase {
    func testNanoIsTheRecommendedFirstModelAndTurboRemainsSelectable() {
        XCTAssertEqual(DesktopChatterboxModel.allCases, [.nano, .turbo])
        XCTAssertTrue(DesktopChatterboxModel.nano.title.contains("recommended"))
        XCTAssertTrue(DesktopChatterboxModel.turbo.title.contains("higher memory"))
    }

    func testThirdPartyVoiceCannotBeUsedBeforeExactNoticeAcceptance() throws {
        let name = "DesktopVoiceOnboardingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertTrue(DesktopVoiceTerms.hasAccepted(.mac, defaults: defaults))
        XCTAssertFalse(DesktopVoiceTerms.hasAccepted(.supertonic, defaults: defaults))
        XCTAssertFalse(DesktopVoiceTerms.hasAccepted(.chatterbox, defaults: defaults))
        DesktopVoiceTerms.accept(.supertonic, defaults: defaults)
        XCTAssertTrue(DesktopVoiceTerms.hasAccepted(.supertonic, defaults: defaults))
        XCTAssertFalse(DesktopVoiceTerms.hasAccepted(.chatterbox, defaults: defaults))
        defaults.set("old-notice", forKey: "desktopVoiceTerms.supertonic")
        XCTAssertFalse(DesktopVoiceTerms.hasAccepted(.supertonic, defaults: defaults))
        DesktopVoiceTerms.accept(.chatterbox, variant: .nano, defaults: defaults)
        XCTAssertTrue(DesktopVoiceTerms.hasAccepted(.chatterbox, variant: .nano, defaults: defaults))
        XCTAssertFalse(DesktopVoiceTerms.hasAccepted(.chatterbox, variant: .turbo, defaults: defaults))
        DesktopVoiceTerms.accept(.chatterbox, variant: .turbo, defaults: defaults)
        XCTAssertTrue(DesktopVoiceTerms.hasAccepted(.chatterbox, variant: .nano, defaults: defaults))
        XCTAssertTrue(DesktopVoiceTerms.hasAccepted(.chatterbox, variant: .turbo, defaults: defaults))
        defaults.set("old-notice", forKey: "desktopVoiceTerms.chatterbox.turbo")
        XCTAssertFalse(DesktopVoiceTerms.hasAccepted(.chatterbox, variant: .turbo, defaults: defaults))
    }
}
