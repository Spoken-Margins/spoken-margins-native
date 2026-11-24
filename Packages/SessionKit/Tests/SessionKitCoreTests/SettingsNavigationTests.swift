import XCTest
@testable import SessionKit

final class SettingsNavigationTests: XCTestCase {
    func testNoRequestKeepsThePath() {
        XCTAssertEqual(SettingsNavigation.path(current: [], request: nil), [])
        XCTAssertEqual(SettingsNavigation.path(current: [.voices], request: nil), [.voices])
        XCTAssertEqual(SettingsNavigation.path(current: [.importInbox], request: nil), [.importInbox])
    }

    func testImportInboxRequestReplacesThePath() {
        XCTAssertEqual(SettingsNavigation.path(current: [], request: .importInbox), [.importInbox])
        XCTAssertEqual(SettingsNavigation.path(current: [.voices], request: .importInbox), [.importInbox])
        XCTAssertEqual(SettingsNavigation.path(current: [.voices, .importInbox], request: .importInbox), [.importInbox])
    }

    func testRepeatedRequestForTheShownPageKeepsOnePage() {
        XCTAssertEqual(SettingsNavigation.path(current: [.importInbox], request: .importInbox), [.importInbox])
        XCTAssertEqual(SettingsNavigation.path(current: [.voices], request: .voices), [.voices])
    }

    func testVoicesRequestFromInboxReplacesIt() {
        XCTAssertEqual(SettingsNavigation.path(current: [.importInbox], request: .voices), [.voices])
        XCTAssertEqual(SettingsNavigation.path(current: [], request: .voices), [.voices])
    }
}
