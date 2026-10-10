import Foundation
import XCTest
@testable import SessionKit

/// Which words of a podcast's transcript an exported Margin carries as its "before" and "after" context:
/// 90 seconds before the Margin's own media time and 120 seconds after it (`SourceAnchorContextResolver`).
///
/// `testNativeAudioExportReResolvesLegacyOversizedAnchorsFromStoredTimeline` (Mac-only target) puts the Margin at
/// the exact middle of the episode, at the session's own playhead, and asserts only that the context is shorter
/// than half the transcript. A context taken from the start of the episode, or from the playhead instead of the
/// Margin, or with a wrong-sized window, passed. Here the transcript says one numbered word per second, so the
/// words in the export name the seconds they cover.
final class NativeAudioExportAnchorWindowTests: XCTestCase {
    private let item = Item(
        id: "item-window", title: "Window Podcast", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
        externalReference: "https://example.com/episode", status: "ready",
        media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 600_000)
    )
    /// word000 starts at 0 s, word001 at 1 s, up to word599: one word a second for ten minutes.
    private let transcript = (0..<600).map { String(format: "word%03d", $0) }.joined(separator: " ")

    func testTheExportedContextIsTheWindowAroundTheMarginsOwnTimeNotThePlayhead() throws {
        // The listener is at 400 s now but recorded the Margin at 120 s.
        let (engine, repository, session) = try makeEngine(playheadMs: 400_000, margins: [("ij-mid", 120_000)])

        let exported = try XCTUnwrap(try export(engine, session).first)

        XCTAssertEqual(span(of: exported.anchorBefore), "word030...word119 (90 words)", "90 s up to the Margin: 30 s to 120 s")
        XCTAssertEqual(span(of: exported.anchorAfter), "word120...word239 (120 words)", "120 s from the Margin: 120 s to 240 s")
        XCTAssertEqual(exported.mediaTimeMs, 120_000)
        XCTAssertEqual(try repository.loadInterjections(sessionId: session.id).first?.anchor.anchorBefore, transcript,
                       "the stored legacy anchor is not rewritten by an export")
    }

    func testTheContextStopsAtTheStartAndTheEndOfTheEpisode() throws {
        let (engine, _, session) = try makeEngine(playheadMs: 300_000, margins: [("ij-early", 10_000), ("ij-late", 595_000)])

        let exported = Dictionary(uniqueKeysWithValues: try export(engine, session).map { ($0.id, $0) })

        let early = try XCTUnwrap(exported["ij-early"])
        XCTAssertEqual(span(of: early.anchorBefore), "word000...word009 (10 words)", "nothing before the start of the episode")
        XCTAssertEqual(span(of: early.anchorAfter), "word010...word129 (120 words)")
        let late = try XCTUnwrap(exported["ij-late"])
        XCTAssertEqual(span(of: late.anchorBefore), "word505...word594 (90 words)")
        XCTAssertEqual(span(of: late.anchorAfter), "word595...word599 (5 words)", "nothing after the end of the episode")
    }

    // MARK: Fixtures

    private func makeEngine(playheadMs: Int, margins: [(id: String, mediaTimeMs: Int)]) throws -> (SessionEngine, InMemorySessionRepository, Session) {
        let session = Session(
            id: "session-window", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: item.id,
            position: Position(mediaTimeMs: playheadMs), completionPercent: 50, playbackRate: 1
        )
        // Margins saved by an older build carried the whole transcript as their before and after text.
        let legacyMargins = margins.map { margin in
            Interjection(
                id: margin.id, itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 50,
                anchor: Anchor(
                    anchorType: .transcript, startChar: 0, endChar: transcript.count,
                    anchorBefore: transcript, anchorAfter: transcript,
                    mediaTimeMs: margin.mediaTimeMs, transcriptSegmentId: "whole-episode"
                ),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
                transcript: "A thought at \(margin.mediaTimeMs).", cleanedTranscript: nil, displayText: nil, status: "active"
            )
        }
        let timeline = SourceTranscriptTimeline(
            id: "transcript-window", itemId: item.id, createdAt: Date(timeIntervalSince1970: 1),
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(
                    id: "whole-episode", startMs: 0, endMs: 600_000, startChar: 0, endChar: transcript.count, text: transcript
                )],
                chapters: [], durationMs: 600_000
            )
        )
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: Dictionary(uniqueKeysWithValues: legacyMargins.map { ($0.id, $0) }),
            transcriptTimelines: [item.id: timeline]
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone-tablet-online", displayName: "Phone/Tablet Online", capabilities: ["sync": ["canonical_persistence"]]
            ),
            repository: repository
        )
        return (engine, repository, session)
    }

    private func export(_ engine: SessionEngine, _ session: Session) throws -> [ExportInterjection] {
        try engine.buildExport(options: ExportOptions(
            sessionId: session.id, includeFullText: false, includeReference: true,
            includeListeningMap: false, includeInterjections: true
        )).interjections
    }

    /// "word030...word119 (90 words)": the first and last numbered word of a context and how many it holds, after
    /// checking they run without a gap.
    private func span(of context: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let words = context.split(separator: " ").map(String.init)
        guard let first = words.first, let last = words.last,
              let firstNumber = Int(first.dropFirst(4)), let lastNumber = Int(last.dropFirst(4)) else { return "no words" }
        XCTAssertEqual(words, (firstNumber...lastNumber).map { String(format: "word%03d", $0) }, "no gaps or repeats", file: file, line: line)
        return "\(first)...\(last) (\(words.count) words)"
    }
}
