import Foundation
import XCTest
@testable import SessionKit

/// #283: the snapshot's failure belongs to the item it happened on. The app's diagnostics record
/// `snapshot.lastFailure` on every `playback.state` event, so a failure left over from the previous
/// item made an export look as if the next item had failed too.
final class ItemSwitchFailureTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence", "browser_session_handoff"],
            "playback": ["realtime_tts", "prerendered_audio", "native_media"],
            "timeline": ["transcript_segments", "media_time", "chapter_timing"]
        ]
    )

    /// An article whose rendered narration file is gone, with a saved session still playing that
    /// file: opening it moves to live speech and records `prepared_audio_unavailable:file_missing` (#237).
    private func articleWithMissingNarration(_ id: String) -> (item: Item, session: Session) {
        let fileURL = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).m4a")
        let item = Item(
            id: id, title: "Article \(id)", mediaType: "text",
            text: "First sentence. Second sentence.", externalReference: nil, status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered, url: fileURL.absoluteString,
                durationMs: 2_300, nativeMediaId: fileURL.absoluteString
            )
        )
        let session = Session(
            id: "session-\(id)", itemId: id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: fileURL.absoluteString,
            position: Position(charOffset: 0, mediaTimeMs: 0, chapterId: nil),
            completionPercent: 0, playbackRate: 1
        )
        return (item, session)
    }

    private let plainText = Item(
        id: "item-plain", title: "Plain article", mediaType: "text",
        text: "Nothing wrong with this one.", externalReference: nil, status: "ready"
    )

    private func engine(_ articles: [(item: Item, session: Session)]) -> SessionEngine {
        var items = [plainText.id: plainText]
        var sessions: [String: Session] = [:]
        for article in articles {
            items[article.item.id] = article.item
            sessions[article.session.id] = article.session
        }
        return SessionEngine(profile: profile, repository: InMemorySessionRepository(items: items, sessions: sessions))
    }

    func testStartingADifferentItemDropsThePreviousItemsFailure() throws {
        let broken = articleWithMissingNarration("item-broken")
        let engine = engine([broken])

        _ = try engine.inspectSession(sessionId: broken.session.id)
        let fellBack = try engine.resumePlayback()
        XCTAssertEqual(fellBack.itemId, broken.item.id)
        XCTAssertEqual(fellBack.lastFailure, "prepared_audio_unavailable:file_missing", "the #237 fallback records why")

        let next = try engine.startSession(itemId: plainText.id)
        XCTAssertEqual(next.itemId, plainText.id)
        XCTAssertNil(next.lastFailure, "the plain article didn't fail")
    }

    func testAFailureRaisedWhileTheNextItemOpensIsStillReported() throws {
        let first = articleWithMissingNarration("item-first")
        let second = articleWithMissingNarration("item-second")
        let engine = engine([first, second])

        _ = try engine.inspectSession(sessionId: first.session.id)
        XCTAssertEqual(try engine.resumePlayback().lastFailure, "prepared_audio_unavailable:file_missing")
        XCTAssertNil(try engine.startSession(itemId: plainText.id).lastFailure)

        // The second article's own narration is missing too: that failure is raised while it opens.
        let opened = try engine.inspectSession(sessionId: second.session.id)
        XCTAssertEqual(opened.itemId, second.item.id)
        XCTAssertEqual(opened.lastFailure, "prepared_audio_unavailable:file_missing")
        XCTAssertEqual(try engine.resumePlayback().lastFailure, "prepared_audio_unavailable:file_missing")
    }

    func testStartingTheSameItemAgainKeepsItsFailure() throws {
        let broken = articleWithMissingNarration("item-broken")
        let engine = engine([broken])

        _ = try engine.inspectSession(sessionId: broken.session.id)
        _ = try engine.resumePlayback()
        XCTAssertEqual(try engine.startSession(itemId: broken.item.id).lastFailure, "prepared_audio_unavailable:file_missing")
    }

    func testImportingABrowserArticleDropsThePreviousItemsFailure() throws {
        let broken = articleWithMissingNarration("item-broken")
        let engine = engine([broken])

        _ = try engine.inspectSession(sessionId: broken.session.id)
        XCTAssertNotNil(try engine.resumePlayback().lastFailure)

        let imported = try engine.importBrowserText(BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/shared", title: "Shared article"),
            text: "A shared article with nothing wrong."
        ))
        XCTAssertNotEqual(imported.itemId, broken.item.id)
        XCTAssertNil(imported.lastFailure)
    }
}
