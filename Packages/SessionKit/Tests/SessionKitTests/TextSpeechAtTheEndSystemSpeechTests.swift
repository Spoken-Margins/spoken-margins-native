import Foundation
import XCTest
import SessionKitTestInputs
@testable import SessionKit
@testable import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation

/// `TextSpeechAtTheEndTests`' inventory with the real `SystemSpeechPlaybackClient`, whose refusal comes from
/// `SpeechPlaybackPlanner` (#4067). Nothing is spoken: the test never lets the synthesizer start.
final class TextSpeechAtTheEndSystemSpeechTests: XCTestCase {
    private func makeSpeech() -> SystemSpeechPlaybackClient {
        let speech = SystemSpeechPlaybackClient(voiceIdentifier: nil, speechRate: AVSpeechUtteranceDefaultSpeechRate)
        speech.speakNarration = { _, _ in }
        return speech
    }

    func testEveryEntryPointLandsAtTheEndWithTheSystemSpeechClient() throws {
        try TextSpeechAtTheEndInventory.run(audio: { makeSpeech() })
    }

    func testAMoveAwayFromTheEndAfterARefusedStartIsNotTakenForTheEnd() throws {
        try TextSpeechAtTheEndInventory.moveAwayAfterARefusedStart(audio: makeSpeech())
    }

    func testAMarginAtTheEndOfAGeneratedTurnLandsThereWithTheSystemSpeechClient() throws {
        try TextSpeechAtTheEndInventory.generatedTurnMarginAtTheEnd(audio: { makeSpeech() })
    }
}
#endif
