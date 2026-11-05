import Foundation
import XCTest
@testable import SessionKit

/// #3412 audit: one answer to "what does this friend's Margin sound like", asked by every way of playing one. The Timeline
/// tap on a written Margin failed because that path alone asked the recording's path and nothing else.
final class SharedMarginAudioTests: XCTestCase {
    private let layer = ImportedCommentaryLayer(
        id: "ana", itemId: "item", packageDigest: "digest", packageId: "package",
        itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
        displayLabel: "Ana", importedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceResolutionStatus: .resolved,
        isEnabled: true, isMuted: false, deletedAt: nil
    )

    private func margin(audioPath: String?, words: String) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "m", layerId: "ana", packageScopedId: "m", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: words,
            audioPath: audioPath, audioDurationMs: audioPath == nil ? nil : 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 60_000, confidence: 1),
            firstHeardAt: nil, replyLinks: nil
        )
    }

    private let recording = URL(fileURLWithPath: "/tmp/ana.m4a")
    private let readingFile = URL(fileURLWithPath: "/tmp/reading.caf")

    private func resolve(_ margin: ImportedCommentaryInterjection, recordingExists: Bool = true, readingReady: Bool = false) -> SharedMarginAudio {
        SharedMarginAudio.resolve(margin, in: layer, voiceFile: { _ in recordingExists ? recording : nil },
                                  reading: { _ in (readingFile, readingReady) })
    }

    func testARecordingThatIsOnThePhoneIsTheAnswer() {
        XCTAssertEqual(resolve(margin(audioPath: "a.m4a", words: "Words")), .voiceFile(recording))
    }

    func testAWrittenMarginIsAReadingReadyOrStillRendering() throws {
        let written = margin(audioPath: nil, words: "Lovely harbour.")
        let reading = try XCTUnwrap(WrittenMarginReading.of(written, in: layer))
        XCTAssertEqual(reading.spokenText, "Ana wrote: Lovely harbour.")
        XCTAssertEqual(resolve(written, readingReady: true), .readingReady(reading, file: readingFile))
        XCTAssertEqual(resolve(written, readingReady: false), .readingRendering(reading, file: readingFile))
        XCTAssertEqual(resolve(written).file, readingFile, "a reading still rendering names the file it will have")
    }

    /// The neighbouring inputs: each is something the Timeline, the card and the review used to judge in their own way.
    func testNeighbouringMarginsAreJudgedTheSameWayEverywhere() {
        // A recording that is gone is a recording problem, never a reading: even with words, it is not read aloud.
        XCTAssertEqual(resolve(margin(audioPath: "gone.m4a", words: "Words that look like a note"), recordingExists: false), .cannotBeRead)
        XCTAssertEqual(resolve(margin(audioPath: "gone.m4a", words: ""), recordingExists: false), .cannotBeRead)
        // A voice Margin's stand-in words are not the sender's words.
        XCTAssertEqual(resolve(margin(audioPath: nil, words: "Voice Margin at 12:34 in “Harbour Lights”")), .cannotBeRead)
        XCTAssertEqual(resolve(margin(audioPath: nil, words: "")), .cannotBeRead)
        XCTAssertEqual(resolve(margin(audioPath: nil, words: "   \n")), .cannotBeRead)
        XCTAssertEqual(resolve(margin(audioPath: nil, words: "🎧🔥")), .cannotBeRead, "nothing the voice can say")
        XCTAssertEqual(resolve(margin(audioPath: nil, words: "https://example.com/x")), .cannotBeRead)
        XCTAssertNotEqual(resolve(margin(audioPath: nil, words: "🎧 great episode")), .cannotBeRead)
        XCTAssertNotEqual(resolve(margin(audioPath: nil, words: "नमस्ते दुनिया")), .cannotBeRead)
        XCTAssertNotEqual(resolve(margin(audioPath: nil, words: String(repeating: "x", count: 50_000))), .cannotBeRead)
        XCTAssertNil(resolve(margin(audioPath: nil, words: "")).file)
    }

    /// What a screen may offer is decided from the Margin alone and agrees with what `resolve` can ever play.
    func testOfferingAgreesWithWhatCanPlay() {
        let cases: [(String?, String)] = [("a.m4a", "Words"), ("a.m4a", ""), (nil, "Words"), (nil, ""), (nil, "🎧"), (nil, "Voice Margin at 1:02")]
        for (path, words) in cases {
            let item = margin(audioPath: path, words: words)
            XCTAssertEqual(SharedMarginAudio.canOffer(item), resolve(item) != .cannotBeRead, "\(String(describing: path)) / \(words)")
        }
    }

    /// Finding 2: the words follow what the Margin is.
    func testTheWordsToTheListenerFollowTheMargin() {
        XCTAssertEqual(SharedMarginAudio.unavailableWords(for: margin(audioPath: "gone.m4a", words: "Some words")), "That Margin's recording couldn't play.")
        XCTAssertEqual(SharedMarginAudio.unavailableWords(for: margin(audioPath: nil, words: "🎧")), "This Margin can't be read aloud on this iPhone.")
        for item in [margin(audioPath: "gone.m4a", words: ""), margin(audioPath: "gone.m4a", words: "Words")] {
            XCTAssertFalse(SharedMarginAudio.unavailableWords(for: item).contains("read aloud"), "a voice Margin is never 'read aloud'")
        }
    }
}
