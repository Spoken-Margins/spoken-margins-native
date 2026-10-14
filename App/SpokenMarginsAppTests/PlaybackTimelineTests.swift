import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class PlaybackTimelineTests: XCTestCase {
    /// #1291 APO-09: `Gate1FlowUITests` checked only that some Timeline row reads "Current chapter." after Next
    /// chapter, which is true before the jump too, and that class runs nowhere. Here the model's real Next chapter
    /// press must move the Timeline's current chapter from the one playing to the next one, and only that one.
    func testNextChapterMovesTheTimelinesCurrentChapterToTheNextChapter() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let (model, cleanUp) = try seededModel()
        defer { cleanUp() }
        model.startItem(id: "item-pill")
        let before = currentTimelineChapterIDs(model)
        XCTAssertEqual(before.count, 1, "precondition: one Timeline chapter is current while the item plays")
        let next = try XCTUnwrap(model.nextPlaybackChapter, "precondition: the seeded item has a next chapter")
        XCTAssertNotEqual(before, [next.id])
        XCTAssertTrue(model.canJumpToNextChapter)

        model.jumpToNextChapter()

        XCTAssertEqual(currentTimelineChapterIDs(model), [next.id], "Next chapter moves the Timeline's current chapter")
        XCTAssertEqual(model.snapshot.chapterTitle, next.title)
        XCTAssertEqual(model.screen, .playback)
    }

    /// #1291 APO-09: the same UI test tapped the forward and back buttons and asserted nothing. A text item's
    /// skip forward must move the reading position on, and skip back must move it back again.
    func testTextSkipForwardThenBackMovesTheReadingPositionOnAndBack() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let (model, cleanUp) = try seededModel()
        defer { cleanUp() }
        model.startItem(id: "item-pill")
        model.skipUnit = "paragraph"
        let start = try XCTUnwrap(model.snapshot.currentTextStart, "precondition: the item is read as text")

        model.skipForward()
        let forward = try XCTUnwrap(model.snapshot.currentTextStart)
        XCTAssertGreaterThan(forward, start, "skip forward moves the reading position on")

        model.skipBack()
        let back = try XCTUnwrap(model.snapshot.currentTextStart)
        XCTAssertLessThan(back, forward, "skip back moves the reading position back")
        XCTAssertNil(model.lastError)
    }

    private func seededModel() throws -> (Gate1AppModel, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appendingPathComponent("library.sqlite"))
        model.resetAndSeed()
        return (model, { try? FileManager.default.removeItem(at: root) })
    }

    /// The chapter rows the Timeline marks "Current chapter", read the way the rail reads them.
    private func currentTimelineChapterIDs(_ model: Gate1AppModel) -> [String] {
        ExperienceTimelineRailScreen.makeEntries(from: model.selectedItem, sessionID: model.snapshot.sessionId)
            .compactMap { entry in
                guard case .chapter(let chapter) = entry.action, model.isCurrentTimelineChapter(chapter) else { return nil }
                return chapter.id
            }
    }

    /// The Terms gate holds text playback on a fresh simulator, so accept them for the test and put them back.
    private func acceptTerms() -> () -> Void {
        let keys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
        return {
            for (key, value) in zip(keys, prior) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }
}
