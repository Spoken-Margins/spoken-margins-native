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
