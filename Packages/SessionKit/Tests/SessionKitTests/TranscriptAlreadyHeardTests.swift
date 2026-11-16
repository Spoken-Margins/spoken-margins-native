import Foundation
import SessionKit
import SessionKitPersistence
@testable import SessionKitSharing
import XCTest

/// #2997 PR 4, the Design's `already-heard` row: a friend's Margins made on a transcript item arrive on the listener's
/// own import of the same file. The friend's file and the listener's differ in layout (a `.vtt` and an `.srt` of one
/// meeting), so only the words are shared. Both sides are real imports into real SQLite stores; the match, the anchor and
/// its placement are the same code a packet goes through. The two copies read as identical text, so placement takes the
/// exact-edition offsets; placement in text that differs is covered by the article anchor tests.
final class TranscriptAlreadyHeardTests: XCTestCase {
    private var root: URL!
    private let utc = TimeZone(identifier: "UTC")!

    private let senderFile = """
    WEBVTT

    1
    00:00:03.500 --> 00:00:06.000
    Alice Example: Welcome everyone, let's start with the budget.

    2
    00:00:06.500 --> 00:00:09.000
    Ben Sample: Thanks. I have the draft numbers ready.

    3
    00:00:09.500 --> 00:00:12.000
    Alice Example: Great, please share them.
    """

    private let listenerFile = """
    1
    00:00:03,500 --> 00:00:06,000
    Alice Example: Welcome everyone, let's start with the budget.

    2
    00:00:06,500 --> 00:00:09,000
    Ben Sample: Thanks. I have the draft numbers ready.

    3
    00:00:09,500 --> 00:00:12,000
    Alice Example: Great, please share them.
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-heard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore(_ name: String) throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: root.appendingPathComponent("\(name).sqlite").path)
    }

    private func importTranscript(_ name: String, _ text: String, into store: SQLiteSessionStore) async throws -> Item {
        let outcome = try await TranscriptLibraryImport.importFile(
            name: name, data: Data(text.utf8), store: store,
            docxText: { _ in throw CancellationError() }, now: Date(timeIntervalSince1970: 1_000), timeZone: utc)
        guard case .added(let id, _, _) = outcome else {
            XCTFail("expected an added transcript, got \(outcome)")
            throw CancellationError()
        }
        return try store.loadItem(id: id)
    }

    /// A written Margin on `words`, made on the sender's copy of the text.
    private func margin(on words: String, in item: Item) throws -> Interjection {
        let text = try XCTUnwrap(item.text)
        let range = try XCTUnwrap(text.range(of: words), "the fixture says \(words)")
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        return Interjection(
            id: "note", itemId: item.id, sessionId: "session", targetType: .item, targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), roughPercent: 50,
            anchor: Anchor(anchorType: .text, startChar: start, endChar: end, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "unavailable", transcriptionStatus: "ready", transcript: "Check this number.",
            cleanedTranscript: nil, displayText: nil, status: "ready")
    }

    private func identity(of item: Item) -> SharedItemIdentity {
        SharedItemIdentityBuilder.localIdentity(
            for: item, textDigests: PortableArticleAnchorResolver.itemTextDigests(item.text ?? ""))
    }

    func testAFriendsMarginOnTheSameMeetingLandsOnTheListenersOwnImportAtTheSameWords() async throws {
        let senderItem = try await importTranscript("budget.vtt", senderFile, into: try openStore("sender"))
        let listenerStore = try openStore("listener")
        // The listener's Library already holds other things, one of them a lookalike with other words.
        try listenerStore.saveItem(Item(
            id: "lookalike", title: "Budget notes", mediaType: "text", text: "Alice: a different meeting, other words entirely.",
            externalReference: "Budget notes.txt", status: "ready", createdAt: Date(timeIntervalSince1970: 2_000)))
        let listenerItem = try await importTranscript("budget.srt", listenerFile, into: listenerStore)
        XCTAssertEqual(listenerItem.text, senderItem.text, "one meeting in two layouts reads as the same words")

        let note = try margin(on: "draft numbers ready", in: senderItem)
        let anchor = SharedMarginExport.anchor(
            for: note, item: senderItem, isNativeAudio: false, mediaChapters: [], machineEvidenceAssetIds: [])
        XCTAssertEqual(anchor.exactText, "draft numbers ready")

        // The packet's item is found among the listener's items by its words, not by file name or the lookalike.
        let items = try listenerStore.listItems()
        let matched = SharedPacketItemMatcher.matchingItemId(
            for: identity(of: senderItem), among: items,
            textDigests: { PortableArticleAnchorResolver.itemTextDigests($0.text ?? "") })
        XCTAssertEqual(matched, listenerItem.id)

        // And the Margin is placed at the same words, by the text rules a Margin on any article follows.
        let placed = PortableArticleAnchorResolver.resolve(
            anchor: anchor, in: try XCTUnwrap(listenerItem.text),
            expectedExactEditionSHA256: identity(of: senderItem).exactEditionSHA256)
        XCTAssertEqual(placed.evidenceClass, .articleTextVerified)
        XCTAssertEqual(placed.localStartChar, note.anchor.startChar)
        XCTAssertEqual(placed.localEndChar, note.anchor.endChar)
        XCTAssertFalse(placed.isAmbiguous)
    }

    func testAnotherMeetingsPacketMatchesNoTranscriptTheListenerHolds() async throws {
        let senderItem = try await importTranscript("budget.vtt", senderFile, into: try openStore("sender"))
        let listenerStore = try openStore("listener")
        let other = senderFile.replacingOccurrences(of: "budget", with: "roadmap")
            .replacingOccurrences(of: "draft numbers", with: "launch dates")
        let listenerItem = try await importTranscript("roadmap.vtt", other, into: listenerStore)
        XCTAssertNotEqual(listenerItem.id, senderItem.id, "other words are another item")

        let matched = SharedPacketItemMatcher.matchingItemId(
            for: identity(of: senderItem), among: try listenerStore.listItems(),
            textDigests: { PortableArticleAnchorResolver.itemTextDigests($0.text ?? "") })
        XCTAssertNil(matched, "a different meeting is not the same work")
    }
}
