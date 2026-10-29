import Foundation
import XCTest
@testable import SessionKit

/// #2505: the Lock Screen card is rebuilt on every playback tick, and each rebuild read the session's Margins and
/// turns from the store on main (three Margin reads and two turn reads per card). It now keeps them until they change.
final class CompactTimelineCacheTests: XCTestCase {
    private final class CountingRepository: InMemorySessionRepository, @unchecked Sendable {
        var interjectionLoads = 0
        var turnLoads = 0
        override func loadInterjections(sessionId: String) throws -> [Interjection] {
            interjectionLoads += 1
            return try super.loadInterjections(sessionId: sessionId)
        }
        override func loadTurns(sessionId: String) throws -> [ConversationTurn] {
            turnLoads += 1
            return try super.loadTurns(sessionId: sessionId)
        }
        var reads: Int { interjectionLoads + turnLoads }
        func resetCounts() { interjectionLoads = 0; turnLoads = 0 }
    }

    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone / Tablet Online",
        capabilities: [
            "playback": ["realtime_tts", "assistant_turn_tts", "summary_turn_tts"],
            "timeline": ["text_char_offsets", "chapter_timing"],
            "interjection": ["record_audio", "capture_text_anchor", "capture_turn_anchor", "delegate_interjection_to_canonical_runtime"],
            "ai": ["summarize_interjections", "continue_discussion"],
            "sync": ["canonical_persistence"],
            "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands", "send_ai_commands"]
        ]
    )

    private func rig() throws -> (SessionEngine, CompactControlDispatcher, CountingRepository, String) {
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let map = ListeningMap(id: "map-pill", itemId: item.id, overview: "", chapters: [
            Chapter(id: "ch-opening", title: "Opening", startChar: 0, endChar: 8, percent: 0),
            Chapter(id: "ch-middle", title: "Middle", startChar: 10, endChar: 22, percent: 50)
        ])
        let repository = CountingRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repository)
        let sessionId = try XCTUnwrap(try engine.startSession(itemId: item.id).sessionId)
        return (engine, CompactControlDispatcher(surfaceProfile: profile, canonicalRuntime: engine), repository, sessionId)
    }

    private func margin(_ id: String, sessionId: String) -> Interjection {
        Interjection(
            id: id, itemId: "item-pill", sessionId: sessionId, targetType: .item, targetId: "item-pill",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: 10, endChar: 13, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "A note.",
            cleanedTranscript: nil, displayText: "A note.", status: "active")
    }

    private func marginEntries(_ dispatcher: CompactControlDispatcher) -> [String] {
        dispatcher.snapshot().timeline.filter { $0.kind == "interjection" }.map(\.id)
    }

    func testTicksReuseTheTimelineTheFirstCardRead() throws {
        let (engine, dispatcher, repository, _) = try rig()
        _ = try engine.syncPlaybackProgress() // the first tick finds the opening chapter, which the card shows
        _ = dispatcher.snapshot()

        var cardReads = 0
        for _ in 0..<10 {
            _ = try engine.syncPlaybackProgress()
            repository.resetCounts()
            _ = dispatcher.snapshot()
            _ = dispatcher.snapshot() // the controller asks again for its own state and diagnostics
            cardReads += repository.reads
        }

        XCTAssertEqual(cardReads, 0, "ten ticks rebuilt the card without reading Margins or turns")
    }

    func testAMarginSavedInTheAppShowsOnceTheAppSaysSo() throws {
        let (_, dispatcher, repository, sessionId) = try rig()
        XCTAssertEqual(marginEntries(dispatcher), [])

        try repository.saveInterjection(margin("m1", sessionId: sessionId))
        dispatcher.noteContentChanged()

        XCTAssertEqual(marginEntries(dispatcher), ["interjection-m1"])
    }

    func testAChapterChangeOrACommandRebuildsTheTimeline() throws {
        let (engine, dispatcher, repository, sessionId) = try rig()
        let before = dispatcher.snapshot().timeline.first { $0.isCurrent }?.id

        _ = try engine.jumpToChapter(chapterId: "ch-middle")
        XCTAssertNotEqual(dispatcher.snapshot().timeline.first { $0.isCurrent }?.id, before, "the current chapter moved")

        try repository.saveInterjection(margin("m2", sessionId: sessionId))
        _ = try dispatcher.dispatch(.pause)
        XCTAssertEqual(marginEntries(dispatcher), ["interjection-m2"], "a command reads the timeline again")
    }
}
