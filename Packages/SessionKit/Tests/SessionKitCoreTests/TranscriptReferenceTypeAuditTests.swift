import Foundation
@testable import SessionKit
import XCTest

/// #2997 PR 2b: an item whose `externalReferenceType` is "transcript" is ordinary text everywhere except its label,
/// noun, icon and place line. Each place that reads the reference type or the media type is asked about both a
/// transcript item and the same text as a plain file import, and must answer the same way. A new switch on the
/// reference type that forgets "transcript" would fail here rather than on a listener's phone.
final class TranscriptReferenceTypeAuditTests: XCTestCase {
    private let body = "Ana: Hello there.\n\nBo: Hi."

    private var transcript: Item {
        Item(
            id: "item-transcript-1", title: "Budget sync", mediaType: "text", text: body,
            externalReference: "Budget sync.vtt", status: "needs_listening_map",
            externalReferenceType: TranscriptItemText.referenceType)
    }

    private var plainFile: Item {
        var item = transcript
        item.externalReferenceType = "file"
        return item
    }

    func testSyncKeysATranscriptByItsTextDigest() {
        let digests = ItemTextDigests(normalizedContentSHA256: "abc", exactEditionSHA256: "def")
        XCTAssertEqual(SyncItemKey.derive(item: transcript, digests: digests), SyncItemKey.derive(item: plainFile, digests: digests))
        XCTAssertNotNil(SyncItemKey.derive(item: transcript, digests: digests))
        XCTAssertNil(SyncItemKey.derive(item: transcript, digests: nil))
    }

    func testTheLibraryTreatsATranscriptAsTextWhenItWordsItsStatusAndPreparesItsAudio() {
        XCTAssertEqual(LibraryRowBuilder.statusLabel(for: transcript), LibraryRowBuilder.statusLabel(for: plainFile))
        XCTAssertEqual(LibraryRowBuilder.shouldPrewarmTextAudio(for: transcript), LibraryRowBuilder.shouldPrewarmTextAudio(for: plainFile))
        XCTAssertEqual(
            LibraryRowWording.contentType(mediaType: "text", sourceReference: "Budget sync.vtt", sourceReferenceType: TranscriptItemText.referenceType),
            LibraryRowWording.contentType(mediaType: "text", sourceReference: "Budget sync.vtt", sourceReferenceType: "file"))
    }

    func testATranscriptHasNoOriginalSourceLinkAndNoFeed() {
        XCTAssertNil(OriginalSourceLink.url(externalReference: "https://example.com/meeting", externalReferenceType: TranscriptItemText.referenceType))
        XCTAssertFalse(ManualFollowPolicy.shouldDiscoverFeed(
            itemId: "item-transcript-1", mediaType: "text", sourceURL: nil,
            sourceReference: "https://example.com/meeting.vtt", sourceReferenceType: TranscriptItemText.referenceType),
            "a transcript is a file from the listener's own files, so even a file name that looks like a link is never followed")
        XCTAssertNil(ManualFollowPolicy.discoveryURL(for: {
            var item = transcript
            item.externalReference = "https://example.com/meeting.vtt"
            return item
        }()))
    }

    func testATranscriptCanNeverEarnThePublicSourceMark() {
        XCTAssertNil(MapTextDisclosure.checkableAddress(of: transcript))
        var linked = transcript
        linked.externalReference = "https://example.com/meeting"
        XCTAssertNil(MapTextDisclosure.checkableAddress(of: linked), "only an item added from a web address has a public copy")
        XCTAssertFalse(MapTextDisclosure.allowsModelText(of: linked))
    }

    func testTheTextReaderIsOfferedForATranscriptWhileItIsSpoken() {
        XCTAssertTrue(PlaybackTextReaderAvailability.isAvailable(
            targetType: TargetType.itemTextTTS.rawValue, itemText: transcript.text ?? "", itemHasNativeAudio: false))
    }
}
