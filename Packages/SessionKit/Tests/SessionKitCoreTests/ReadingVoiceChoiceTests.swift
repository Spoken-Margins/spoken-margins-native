import SessionKit
import XCTest

/// #2226: the reading-voice picker offered James, Lily and the iOS voice only; Kitten read to everyone who had not
/// downloaded Supertonic but could not be chosen. These pin what a stored choice means, so a build that adds a voice
/// cannot change what an older saved choice reads.
final class ReadingVoiceChoiceTests: XCTestCase {
    func testStoredCodesOfTheVoicesEarlierBuildsSavedAreUnchanged() {
        XCTAssertEqual(ReadingVoiceChoice(rawValue: "supertonic:M2"), .james)
        XCTAssertEqual(ReadingVoiceChoice(rawValue: "supertonic:F2"), .lily)
        XCTAssertEqual(ReadingVoiceChoice(rawValue: "system"), .system)
    }

    func testKittenHasItsOwnStoredCodeAndTheListKeepsTheOlderVoicesInOrder() {
        XCTAssertEqual(ReadingVoiceChoice(rawValue: "kitten:jasper"), .kitten)
        XCTAssertEqual(ReadingVoiceChoice.allCases.map(\.rawValue),
                       ["supertonic:M2", "supertonic:F2", "kitten:jasper", "system", "phonon:en", "kokoro:af_heart"])
    }

    func testAnUnknownStoredCodeIsNoChoice() {
        for code in ["", "kitten", "kitten:Jasper", "supertonic:M3", "SYSTEM", "pocket:af"] {
            XCTAssertNil(ReadingVoiceChoice(rawValue: code), code)
        }
    }

    func testKittenReadsOnDeviceWithoutSupertonicOrItsSavedAudio() {
        XCTAssertTrue(ReadingVoiceChoice.kitten.readsOnDevice)
        XCTAssertFalse(ReadingVoiceChoice.kitten.rendersWithSupertonic)
        XCTAssertFalse(ReadingVoiceChoice.kitten.playsSavedSupertonicAudio)
        XCTAssertTrue(ReadingVoiceChoice.kitten.bundledVoiceIsChosen)
    }

    func testJamesAndLilyKeepSupertonicAndItsSavedAudio() {
        for choice in [ReadingVoiceChoice.james, .lily] {
            XCTAssertTrue(choice.readsOnDevice, choice.rawValue)
            XCTAssertTrue(choice.rendersWithSupertonic, choice.rawValue)
            XCTAssertTrue(choice.playsSavedSupertonicAudio, choice.rawValue)
            XCTAssertFalse(choice.bundledVoiceIsChosen, choice.rawValue)
        }
    }

    func testTheIOSVoiceIsNotOnDevice() {
        XCTAssertFalse(ReadingVoiceChoice.system.readsOnDevice)
        XCTAssertFalse(ReadingVoiceChoice.system.rendersWithSupertonic)
        XCTAssertFalse(ReadingVoiceChoice.system.bundledVoiceIsChosen)
    }

    /// #2700: Phonon and Kokoro read on device, never with Supertonic or its saved audio, and their own saved audio
    /// may play, which is what lets a saved run of the chosen voice follow the #1680 seam rule.
    func testDownloadedVoicesPlayTheirOwnSavedAudioAndNeverSupertonics() {
        XCTAssertEqual(ReadingVoiceChoice.phonon.downloadedVoiceId, "phonon-31m-en")
        XCTAssertEqual(ReadingVoiceChoice.kokoro.downloadedVoiceId, "kokoro-82m")
        for choice in [ReadingVoiceChoice.phonon, .kokoro] {
            XCTAssertTrue(choice.readsOnDevice, choice.rawValue)
            XCTAssertFalse(choice.rendersWithSupertonic, choice.rawValue)
            XCTAssertFalse(choice.playsSavedSupertonicAudio, choice.rawValue)
            XCTAssertTrue(choice.playsSavedChosenVoiceAudio, choice.rawValue)
            XCTAssertFalse(choice.bundledVoiceIsChosen, choice.rawValue)
        }
    }

    func testOnlySupertonicAndDownloadedVoicesHaveChosenVoiceSavedAudio() {
        XCTAssertTrue(ReadingVoiceChoice.james.playsSavedChosenVoiceAudio)
        XCTAssertTrue(ReadingVoiceChoice.lily.playsSavedChosenVoiceAudio)
        XCTAssertFalse(ReadingVoiceChoice.kitten.playsSavedChosenVoiceAudio)
        XCTAssertFalse(ReadingVoiceChoice.system.playsSavedChosenVoiceAudio)
        for choice in [ReadingVoiceChoice.james, .lily, .kitten, .system] {
            XCTAssertNil(choice.downloadedVoiceId, choice.rawValue)
        }
    }
}
