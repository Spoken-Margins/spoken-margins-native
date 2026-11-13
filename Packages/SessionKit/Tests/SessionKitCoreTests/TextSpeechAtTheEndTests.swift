import Foundation
import XCTest
import SessionKitTestInputs
@testable import SessionKit

/// Starting text speech where nothing is left to read lands the listener at the end of the item (#4067). The entry
/// points are in `TextSpeechAtTheEndInventory`; this runs them with a client that has the real one's refusal, on every
/// host. `TextSpeechAtTheEndSystemSpeechTests` runs them with the real client on a Mac.
final class TextSpeechAtTheEndTests: XCTestCase {
    func testEveryEntryPointLandsAtTheEndWithAClientThatRefusesAnEmptyStart() throws {
        try TextSpeechAtTheEndInventory.run(audio: { TextSpeechAtTheEndInventory.RefusingAtTheEndSpeech() })
    }

    /// A move after the refused start clears it: the item is not read as finished where the listener moved to.
    func testAMoveAwayFromTheEndAfterARefusedStartIsNotTakenForTheEnd() throws {
        try TextSpeechAtTheEndInventory.moveAwayAfterARefusedStart(audio: TextSpeechAtTheEndInventory.RefusingAtTheEndSpeech())
    }

    /// #4199: the generated turns (an AI answer, an interjection summary) take the same answer as an item's text.
    func testAMarginAtTheEndOfAGeneratedTurnLandsThereWithoutAnError() throws {
        try TextSpeechAtTheEndInventory.generatedTurnMarginAtTheEnd(audio: { TextSpeechAtTheEndInventory.RefusingAtTheEndSpeech() })
    }

    func testARefusedStartStopsTheSpeechThatWasPlaying() throws {
        try TextSpeechAtTheEndInventory.refusedStartStopsTheOldSpeech()
    }

    func testTheReasonsTheClientsGiveAreRecognised() {
        XCTAssertTrue(EmptyTextStart.isNothingLeftToRead("playback_text_empty"))
        XCTAssertTrue(EmptyTextStart.isNothingLeftToRead("supertonic_playback_text_empty"))
        XCTAssertFalse(EmptyTextStart.isNothingLeftToRead("system_speech_projection_unsafe"))
        XCTAssertFalse(EmptyTextStart.isNothingLeftToRead("playback_text_empty_for_now"))
        XCTAssertFalse(EmptyTextStart.isNothingLeftToRead(""))
    }
}
