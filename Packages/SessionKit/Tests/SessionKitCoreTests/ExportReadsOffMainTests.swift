import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The Export screen's preview reads what it shows off the main thread (#2505). Opening Export on a mapped podcast
/// used to read the whole transcript timeline, the Listening Map and every Margin on the main thread before the
/// screen could draw, and every switch in its options read them again.
@MainActor
final class ExportReadsOffMainTests: XCTestCase {
    private static let optionSets: [ExportOptions] = [false, true].flatMap { fullText in
        [false, true].flatMap { map in
            ["full_session", "source_interjections", "original"].map { scope in
                ExportOptions(includeFullText: fullText, includeReference: true, includeListeningMap: map,
                              includeInterjections: true, includeTurns: true, scope: scope)
            }
        }
    }

    func testTheOffMainExportIsTheSameExportForEveryOption() async throws {
        let fixture = try LibraryFixture.build(.small)
        defer { fixture.remove() }
        let engine = Self.engine(try fixture.openStore())
        for sessionId in ["session-0", "session-1", "session-2"] {
            for var options in Self.optionSets {
                options.sessionId = sessionId
                let offMain = try await engine.buildExportReadingOffMain(options: options)
                XCTAssertEqual(offMain, try engine.buildExport(options: options), "\(sessionId) \(options)")
            }
        }
    }

    func testAMappedPodcastsExportReadsNothingOnTheMainThread() async throws {
        let fixture = try LibraryFixture.build(.small)
        defer { fixture.remove() }
        let meter = StoreReadMeter()
        let engine = Self.engine(try fixture.openStore(meter: meter))
        meter.reset() // opening the store reads its journal mode and quarantine count; that is not the export

        let export = try await engine.buildExportReadingOffMain(options: ExportOptions(
            sessionId: "session-0", includeFullText: true, includeReference: true, includeListeningMap: true,
            includeInterjections: true))

        XCTAssertNotNil(export.listeningMap, "the map was asked for and the podcast has one")
        XCTAssertFalse(export.interjections.isEmpty)
        XCTAssertGreaterThan(meter.totals(for: "loadTranscriptTimeline(itemId:)").calls, 0, "the timeline was read")
        XCTAssertEqual(meter.samples.filter(\.onMainThread).map(\.method), [], "no store read on the main thread")
    }

    /// A recording's Margin takes its words from the transcript even when the full text is not exported: the
    /// timeline must be read off main for that case too, and give the same context.
    func testARecordingsMarginContextIsTheSameOffMain() async throws {
        let item = Item(
            id: "item-stream", title: "Stream", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 600_000))
        let transcript = (0..<600).map { "word\($0)" }.joined(separator: " ")
        let session = Session(
            id: "session-stream", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: item.id,
            position: Position(mediaTimeMs: 300_000), completionPercent: 50, playbackRate: 1)
        let margin = Interjection(
            id: "ij-stream", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 20,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "",
                           mediaTimeMs: 120_000, transcriptSegmentId: "whole"),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
            transcript: "A thought.", cleanedTranscript: nil, displayText: nil, status: "active")
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session], interjections: [margin.id: margin],
            transcriptTimelines: [item.id: SourceTranscriptTimeline(
                id: "timeline-stream", itemId: item.id, createdAt: Date(timeIntervalSince1970: 1),
                timeline: TranscriptTimeline(
                    segments: [MediaTimelineSegment(id: "whole", startMs: 0, endMs: 600_000, startChar: 0,
                                                    endChar: transcript.count, text: transcript)],
                    chapters: [], durationMs: 600_000))])
        let engine = Self.engine(repository)
        let options = ExportOptions(sessionId: session.id, includeFullText: false, includeReference: true,
                                    includeListeningMap: false, includeInterjections: true)

        let offMain = try await engine.buildExportReadingOffMain(options: options)

        XCTAssertEqual(offMain, try engine.buildExport(options: options))
        XCTAssertTrue(try XCTUnwrap(offMain.interjections.first).anchorBefore.contains("word119"), "the words before 120 s")
    }

    /// Without a stored session the engine's own session is exported, exactly as before.
    func testWithoutASessionIdItIsTheOrdinaryExport() async throws {
        let fixture = try LibraryFixture.build(.small)
        defer { fixture.remove() }
        let engine = Self.engine(try fixture.openStore())
        let options = ExportOptions(sessionId: "no-such-session", includeFullText: false, includeReference: true,
                                    includeListeningMap: false, includeInterjections: true)
        do {
            _ = try await engine.buildExportReadingOffMain(options: options)
            XCTFail("an unknown session with no current session must fail as buildExport does")
        } catch {
            XCTAssertThrowsError(try engine.buildExport(options: options))
        }
    }

    private static func engine(_ repository: SessionRepository) -> SessionEngine {
        SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone-tablet-online", displayName: "Phone/Tablet Online", capabilities: ["sync": ["canonical_persistence"]]),
            repository: repository)
    }
}
