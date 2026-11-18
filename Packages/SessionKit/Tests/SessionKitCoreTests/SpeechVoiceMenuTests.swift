import XCTest
@testable import SessionKit

/// #4020: the Settings Speech Voice row and page name and order the iOS voices by these rules.
final class SpeechVoiceMenuTests: XCTestCase {
    private typealias Voice = SpeechVoiceMenu.Voice
    private let english = Locale(identifier: "en_US")

    private func voice(_ name: String, _ language: String = "en-US", _ quality: String = "Default", id: String? = nil) -> Voice {
        Voice(id: id ?? "com.apple.voice.\(quality.lowercased()).\(language).\(name)", name: name, language: language, quality: quality)
    }

    private func menu(_ voices: [Voice], chosen: String = "", preferred: String? = "en-US") -> SpeechVoiceMenu {
        SpeechVoiceMenu(voices: voices, chosenIdentifier: chosen, preferredLanguage: preferred, locale: english)
    }

    func testNothingChosenReadsSystemVoiceAndMarksIt() {
        let result = menu([voice("Samantha")])
        XCTAssertEqual(result.valueText, "System voice")
        XCTAssertTrue(result.systemVoiceIsChosen)
        XCTAssertFalse(result.isMissing)
        XCTAssertFalse(result.sections.flatMap(\.rows).contains(where: \.isChosen))
    }

    func testAUniqueNameIsJustTheName() {
        let samantha = voice("Samantha")
        let result = menu([samantha, voice("Daniel", "en-GB")], chosen: samantha.id)
        XCTAssertEqual(result.valueText, "Samantha")
        XCTAssertFalse(result.systemVoiceIsChosen)
        XCTAssertEqual(result.sections.flatMap(\.rows).filter(\.isChosen).map(\.id), [samantha.id])
    }

    func testTwoVoicesWithOneNameAndLanguageAddTheQualityToTheValue() {
        let enhanced = voice("Samantha", "en-US", "Enhanced")
        let result = menu([voice("Samantha", "en-US", "Default"), enhanced], chosen: enhanced.id)
        XCTAssertEqual(result.valueText, "Samantha (Enhanced)")
    }

    func testTheSameNameInAnotherLanguageGetsNoBracket() {
        let american = voice("Alex", "en-US")
        let result = menu([american, voice("Alex", "en-GB")], chosen: american.id)
        XCTAssertEqual(result.valueText, "Alex", "the page's sections tell the languages apart")
    }

    func testAChosenVoiceTheLoadedListLacksIsNotInstalled() {
        let result = menu([voice("Samantha")], chosen: "com.apple.voice.enhanced.en-US.Zoe")
        XCTAssertEqual(result.valueText, "Not installed")
        XCTAssertTrue(result.isMissing)
        XCTAssertFalse(result.systemVoiceIsChosen)
        XCTAssertFalse(result.sections.flatMap(\.rows).contains(where: \.isChosen))
    }

    func testAnEmptyListNamesTheVoiceFromItsIdentifierAndIsNeverMissing() {
        let result = menu([], chosen: "com.apple.voice.enhanced.en-US.Samantha")
        XCTAssertEqual(result.valueText, "Samantha")
        XCTAssertFalse(result.isMissing, "an empty list is \"can't tell\", as playback treats it")
        XCTAssertTrue(result.sections.isEmpty)
    }

    func testAnIdentifierWithoutDotsIsItsOwnName() {
        XCTAssertEqual(menu([], chosen: "Samantha").valueText, "Samantha")
    }

    func testTheDeviceLanguageComesFirstThenTheRestAlphabetically() {
        let voices = [
            voice("Anna", "de-DE"), voice("Thomas", "fr-FR"), voice("Samantha", "en-US"), voice("Daniel", "en-GB"),
            voice("Karen", "en-AU"),
        ]
        let result = menu(voices, preferred: "en-GB")
        XCTAssertEqual(result.sections.map(\.id), ["en-GB", "en-AU", "en-US", "fr-FR", "de-DE"],
                       "the exact region, then other English sections, then the rest by header (French before German)")
    }

    func testTheDeviceLanguageMatchesWhateverSeparatorOrCase() {
        let voices = [voice("Anna", "de-DE"), voice("Daniel", "en-GB")]
        XCTAssertEqual(menu(voices, preferred: "en_gb").sections.map(\.id), ["en-GB", "de-DE"])
        XCTAssertEqual(menu(voices, preferred: "en").sections.map(\.id), ["en-GB", "de-DE"])
        XCTAssertEqual(menu(voices, preferred: nil).sections.map(\.id), ["en-GB", "de-DE"], "no device language: by header (English before German)")
    }

    func testHeadersNameTheLanguageInTheListenersLanguage() {
        let result = menu([voice("Samantha")])
        XCTAssertEqual(result.sections.first?.header, english.localizedString(forIdentifier: "en-US"))
        XCTAssertNotEqual(result.sections.first?.header, "en-US")
    }

    func testAnUnknownLanguageCodeIsItsOwnHeader() {
        let result = menu([voice("Nobody", "zz")])
        XCTAssertEqual(result.sections.first?.header, english.localizedString(forIdentifier: "zz") ?? "zz")
    }

    func testRowsSortByNameThenQuality() {
        let voices = [
            voice("Zoe", "en-US", "Default"), voice("Alex", "en-US", "Default"), voice("Alex", "en-US", "Premium"),
            voice("alice", "en-US", "Enhanced"), voice("Alex", "en-US", "Unknown"), voice("Alex", "en-US", "Enhanced"),
        ]
        let rows = menu(voices).sections.first?.rows ?? []
        XCTAssertEqual(rows.map { "\($0.name) \($0.quality)" },
                       ["Alex Premium", "Alex Enhanced", "Alex Default", "Alex Unknown", "alice Enhanced", "Zoe Default"])
    }

    func testEveryVoiceAppearsOnceAndNoRowRepeatsItsLanguage() {
        let voices = [voice("A", "en-US"), voice("B", "en-US"), voice("C", "fr-FR")]
        let rows = menu(voices).sections.flatMap(\.rows)
        XCTAssertEqual(Set(rows.map(\.id)), Set(voices.map(\.id)))
        XCTAssertEqual(rows.count, voices.count)
    }
}
