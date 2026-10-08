import XCTest
@testable import SessionKit

final class NarrationVoiceNoticeTests: XCTestCase {
    func testReplacementPassageIsVisibleAndChosenVoiceRestoresChapterLine() {
        var notice = NarrationVoiceNotice()
        let snapshot = playing("table-pdf")
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: nil), "Rendering ahead isn't playback")
        XCTAssertNil(notice.chapterLine)

        XCTAssertEqual(notice.update(snapshot: snapshot, replacementTargetId: "table-pdf"), NarrationVoiceNotice.bannerMessage)
        XCTAssertEqual(notice.chapterLine, "iOS voice for this part")
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "table-pdf"), "Repeated progress ticks don't repeat the banner")

        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: nil))
        XCTAssertNil(notice.chapterLine, "The view can show the chapter again as soon as the chosen voice returns")
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "table-pdf"), "A later table doesn't repeat the banner")
        XCTAssertEqual(notice.chapterLine, "iOS voice for this part")
    }

    func testBannerBudgetBelongsToEachItemAndSurvivesLeavingAndReturning() {
        var notice = NarrationVoiceNotice()
        XCTAssertNotNil(notice.update(snapshot: playing("pdf-a"), replacementTargetId: "pdf-a"))
        XCTAssertNotNil(notice.update(snapshot: playing("pdf-b"), replacementTargetId: "pdf-b"))
        XCTAssertNil(notice.update(snapshot: SessionSnapshot(), replacementTargetId: nil))
        XCTAssertNil(notice.chapterLine)
        var replay = playing("pdf-a")
        replay.sessionId = "new-session"
        XCTAssertNil(notice.update(snapshot: replay, replacementTargetId: "pdf-a"))
        XCTAssertEqual(notice.chapterLine, "iOS voice for this part")
    }

    func testInactiveOrUnrelatedPlaybackNeitherShowsNoticeNorConsumesBanner() {
        var notice = NarrationVoiceNotice()
        var snapshot = playing("pdf")
        for status in [PlaybackStatus.idle, .starting, .paused, .recording, .failed] {
            snapshot.status = status
            XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "pdf"))
            XCTAssertNil(notice.chapterLine)
        }
        snapshot.status = .playing
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "previous-item"))
        snapshot.targetId = "assistant-turn"
        snapshot.phase = .aiResponsePlayback
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "assistant-turn"))
        snapshot = playing("pdf")
        snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "pdf"))
        snapshot = playing("pdf")
        snapshot.itemId = nil
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "pdf"))
        XCTAssertNil(notice.chapterLine)
        XCTAssertNotNil(notice.update(snapshot: playing("pdf"), replacementTargetId: "pdf"))
        snapshot = playing("pdf")
        snapshot.status = .paused
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "pdf"))
        XCTAssertNil(notice.chapterLine, "Pause clears an active notice")
        XCTAssertNil(notice.update(snapshot: playing("pdf"), replacementTargetId: "pdf"))
        XCTAssertEqual(notice.chapterLine, "iOS voice for this part", "Resume restores the line without another banner")
    }

    /// Each clause of the guard has to be able to refuse on its own. The test above changes the phase and the
    /// target together, so a missing phase clause or a missing target clause would still be refused by another one.
    func testEachGuardClauseRefusesTheNoticeOnItsOwn() {
        // A reply being played with the item's own id as both the target and the replacement: only the phase differs.
        var notice = NarrationVoiceNotice()
        var snapshot = playing("pdf")
        snapshot.phase = .aiResponsePlayback
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "pdf"), "a reply is not item playback")
        XCTAssertNil(notice.chapterLine)
        XCTAssertNotNil(notice.update(snapshot: playing("pdf"), replacementTargetId: "pdf"),
                        "the refused reply did not use up the item's banner")

        // The replacement is the item's, but the chunk playing is another target: only the target differs.
        notice = NarrationVoiceNotice()
        snapshot = playing("pdf")
        snapshot.targetId = "another-chunk"
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "pdf"), "the playing target must be the replacement")
        XCTAssertNil(notice.chapterLine)
        XCTAssertNotNil(notice.update(snapshot: playing("pdf"), replacementTargetId: "pdf"),
                        "the refused target did not use up the item's banner")

        // The replacement names another item than the one playing: only the replacement differs.
        notice = NarrationVoiceNotice()
        snapshot = playing("pdf")
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: "another-item"))
        XCTAssertNil(notice.chapterLine)

        // The item has no id worth announcing.
        notice = NarrationVoiceNotice()
        snapshot = playing("")
        XCTAssertNil(notice.update(snapshot: snapshot, replacementTargetId: ""))
        XCTAssertNil(notice.chapterLine)
    }

    private func playing(_ itemId: String) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = "session-\(itemId)"
        snapshot.itemId = itemId
        snapshot.targetId = itemId
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        snapshot.phase = .itemPlayback
        snapshot.status = .playing
        return snapshot
    }
}
