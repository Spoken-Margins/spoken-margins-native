import XCTest
@testable import DesktopCore

final class DesktopVoiceCatalogTests: XCTestCase {
    private let voices = [
        DesktopVoiceDescriptor(id: "en-us-one", language: "en-US"),
        DesktopVoiceDescriptor(id: "en-gb-one", language: "en-GB"),
        DesktopVoiceDescriptor(id: "fr-one", language: "fr-FR"),
        DesktopVoiceDescriptor(id: "ja-one", language: "ja-JP")
    ]

    func testVoicePickerExcludesOtherLanguages() {
        XCTAssertEqual(DesktopVoiceCatalog.voices(in: "en", from: voices).map(\.id), ["en-us-one", "en-gb-one"])
        XCTAssertEqual(DesktopVoiceCatalog.voices(in: "fr-FR", from: voices).map(\.id), ["fr-one"])
    }

    func testPreferredLanguageUsesExactThenSameLanguageFallback() {
        XCTAssertEqual(
            DesktopVoiceCatalog.preferredLanguage(from: voices, preferredLanguages: ["fr-FR", "en-US"]),
            "fr"
        )
        XCTAssertTrue(
            DesktopVoiceCatalog.preferredLanguage(from: voices, preferredLanguages: ["en-AU"]) == "en"
        )
    }
}
