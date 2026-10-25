import XCTest
@testable import SessionKit

final class CommunityMapKeptTranscriptsTests: XCTestCase {
    private func makeKept() -> CommunityMapKeptTranscripts {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kept-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return CommunityMapKeptTranscripts(folder: folder)
    }

    private func timeline(_ text: String) -> TranscriptTimeline {
        TranscriptTimeline(segments: [MediaTimelineSegment(id: "s", startMs: 0, endMs: 60_000, text: text)], chapters: [], durationMs: 60_000)
    }

    func testASavedTranscriptLoadsBackAndRemoves() {
        let kept = makeKept()
        XCTAssertNil(kept.load(episodeKey: "k"))
        XCTAssertTrue(kept.save(timeline("a"), episodeKey: "k"))
        XCTAssertEqual(kept.load(episodeKey: "k"), timeline("a"))
        XCTAssertNil(kept.load(episodeKey: "other"), "one file per episode")
        kept.remove(episodeKey: "k")
        XCTAssertNil(kept.load(episodeKey: "k"))
    }

    /// The #2629 audit's race: upload A for an episode finishes after attempt B for the same episode has saved
    /// its transcript. A's clean-up must leave B's transcript, or B's retry has nothing to send.
    func testAFinishedUploadLeavesATranscriptANewerAttemptSaved() {
        let kept = makeKept()
        kept.save(timeline("sent by A"), episodeKey: "k")
        kept.save(timeline("saved by B"), episodeKey: "k")
        kept.remove(episodeKey: "k", ifHolding: timeline("sent by A"))
        XCTAssertEqual(kept.load(episodeKey: "k"), timeline("saved by B"))
    }

    func testAFinishedUploadRemovesTheTranscriptItSent() {
        let kept = makeKept()
        kept.save(timeline("sent"), episodeKey: "k")
        kept.remove(episodeKey: "k", ifHolding: timeline("sent"))
        XCTAssertNil(kept.load(episodeKey: "k"))
        kept.remove(episodeKey: "k", ifHolding: timeline("sent"))
        XCTAssertNil(kept.load(episodeKey: "k"), "nothing kept is fine")
    }

    func testRemovingAllClearsTheFolder() {
        let kept = makeKept()
        kept.save(timeline("a"), episodeKey: "k1")
        kept.save(timeline("b"), episodeKey: "k2")
        kept.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.folder.path))
        XCTAssertTrue(kept.save(timeline("c"), episodeKey: "k3"), "the folder is made again on the next save")
    }
}
