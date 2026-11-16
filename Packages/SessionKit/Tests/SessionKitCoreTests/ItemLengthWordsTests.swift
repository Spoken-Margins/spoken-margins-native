import Foundation
import XCTest
@testable import SessionKit

/// #4186 PR 1: one length rule and one set of words for the Library row and the item screen's length pill.
final class ItemLengthWordsTests: XCTestCase {
    private func media(_ type: AudioSourceType, _ ms: Int?) -> ItemMedia { ItemMedia(sourceType: type, url: "u", durationMs: ms) }

    // MARK: PlayableLength

    func testPlayableLengthIsRecordedAudioOfKnownLengthOnly() {
        XCTAssertEqual(PlayableLength.ms(media: media(.nativeMediaFile, 3_725_000)), 3_725_000)
        XCTAssertEqual(PlayableLength.ms(media: media(.remoteStream, 60_000)), 60_000)
        XCTAssertNil(PlayableLength.ms(media: media(.nativeMediaFile, nil)))
        XCTAssertNil(PlayableLength.ms(media: media(.nativeMediaFile, 0)), "0 means not known yet")
        XCTAssertNil(PlayableLength.ms(media: media(.remoteStream, -5)))
        XCTAssertNil(PlayableLength.ms(media: nil))
        // Prepared narration of an article has a media length, but it is text: it keeps its estimate.
        XCTAssertNil(PlayableLength.ms(media: media(.generatedTTSPrerendered, 900_000)))
        XCTAssertNil(PlayableLength.ms(media: media(.generatedTTSRealtime, 900_000)))
        XCTAssertNil(PlayableLength.ms(media: media(.browserOwnedMedia, 900_000)))
    }

    // MARK: total

    func testTotalForRecordedAudioNeverSaysAboutAndIgnoresTheSpeed() {
        let table: [(Int, String, String)] = [
            (59_999, "under 1 min", "less than a minute"),
            (60_000, "1 min", "1 minute"),
            (41 * 60_000, "41 min", "41 minutes"),
            (3_600_000, "1 h", "1 hour"),
            (3_725_000, "1 h 2 min", "1 hour 2 minutes"),
            (4_320_000, "1 h 12 min", "1 hour 12 minutes"),
            (7_200_000, "2 h", "2 hours"),
        ]
        for (ms, visible, spoken) in table {
            for speed in [1.0, 2.0] {
                let words = ItemLengthWords.total(textCharacterCount: nil, mediaDurationMs: ms, playbackSpeed: speed)
                XCTAssertEqual(words?.visible, visible, "\(ms) ms at \(speed)x")
                XCTAssertEqual(words?.spoken, spoken, "\(ms) ms at \(speed)x")
            }
        }
    }

    func testTotalTreatsZeroNegativeAndMissingLengthsAsUnknown() {
        XCTAssertNil(ItemLengthWords.total(textCharacterCount: nil, mediaDurationMs: 0, playbackSpeed: 1))
        XCTAssertNil(ItemLengthWords.total(textCharacterCount: nil, mediaDurationMs: -1, playbackSpeed: 1))
        XCTAssertNil(ItemLengthWords.total(textCharacterCount: nil, mediaDurationMs: nil, playbackSpeed: 1))
    }

    func testTotalForTextIsAnEstimateAtTheListenersSpeed() {
        // 14 characters a second at 1x: 21 000 characters is 25 min.
        let one = ItemLengthWords.total(textCharacterCount: 21_000, mediaDurationMs: nil, playbackSpeed: 1)
        XCTAssertEqual(one?.visible, "about 25 min")
        XCTAssertEqual(one?.spoken, "about 25 minutes")
        XCTAssertEqual(ItemLengthWords.total(textCharacterCount: 21_000, mediaDurationMs: nil, playbackSpeed: 2)?.visible, "about 13 min")
        XCTAssertEqual(ItemLengthWords.total(textCharacterCount: 20, mediaDurationMs: nil, playbackSpeed: 1)?.visible, "under 1 min")
        XCTAssertEqual(ItemLengthWords.total(textCharacterCount: 20, mediaDurationMs: nil, playbackSpeed: 1)?.spoken, "less than a minute")
        // Text wins when a caller passes both, as the Library row always did.
        XCTAssertEqual(ItemLengthWords.total(textCharacterCount: 21_000, mediaDurationMs: 7_200_000, playbackSpeed: 1)?.visible, "about 25 min")
    }

    // MARK: pill

    private func pill(native: Bool = false, meeting: Bool = false, characters: Int? = nil, lengthMs: Int? = nil, speed: Double = 1)
        -> (visible: String, spoken: String)? {
        ItemLengthWords.pill(isNativeAudio: native, isMeetingTranscript: meeting, textCharacterCount: characters, lengthMs: lengthMs, playbackSpeed: speed)
    }

    func testPillForRecordedAudioOfKnownLength() {
        XCTAssertEqual(pill(native: true, lengthMs: 4_320_000)?.visible, "1 h 12 min")
        XCTAssertEqual(pill(native: true, lengthMs: 4_320_000)?.spoken, "Length, 1 hour 12 minutes")
        XCTAssertEqual(pill(native: true, lengthMs: 41 * 60_000)?.visible, "41 min")
        XCTAssertEqual(pill(native: true, lengthMs: 30_000)?.visible, "under 1 min")
        XCTAssertEqual(pill(native: true, lengthMs: 30_000)?.spoken, "Length, less than a minute")
        XCTAssertEqual(pill(native: true, lengthMs: 7_200_000)?.visible, "2 h")
    }

    func testPillForRecordedAudioOfUnknownLengthSaysSoAndWhy() {
        for ms in [nil, 0, -1] as [Int?] {
            XCTAssertEqual(pill(native: true, lengthMs: ms)?.visible, "Length unknown")
            XCTAssertEqual(pill(native: true, lengthMs: ms)?.spoken, "Length unknown. It shows once the episode downloads or plays.")
        }
    }

    func testPillForTextIsTheEstimateAndAMeetingTranscriptOrEmptyTextHasNone() {
        XCTAssertEqual(pill(characters: 21_000)?.visible, "about 25 min")
        XCTAssertEqual(pill(characters: 21_000)?.spoken, "Length, about 25 minutes")
        XCTAssertEqual(pill(characters: 21_000, speed: 2)?.visible, "about 13 min")
        XCTAssertEqual(pill(characters: 20)?.visible, "under 1 min")
        XCTAssertEqual(pill(characters: 20)?.spoken, "Length, less than a minute")
        XCTAssertNil(pill(characters: nil), "text with no character count shows no pill")
        XCTAssertNil(pill(meeting: true, characters: 21_000), "a meeting transcript's meeting line gives its length")
        XCTAssertNil(pill(native: true, meeting: true, lengthMs: 60_000))
    }

    func testPillForTextNeverReadsAnAudioLength() {
        // Prepared narration: text with a media length. The pill is the "about" estimate, never the narration's length.
        XCTAssertEqual(pill(characters: 21_000, lengthMs: 7_200_000)?.visible, "about 25 min")
        XCTAssertNil(pill(characters: nil, lengthMs: 7_200_000))
    }
}
