import Foundation
import XCTest
@testable import SessionKit

/// A reply recorded or written through the normal recorder carries the link to the Margin it answers, and
/// nothing else does (#473). The link rides the begin request, so Finish from the Lock Screen, a Live
/// Activity or the app all save it, and a cancelled reply never leaks into the next Margin.
final class MarginReplyCaptureTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )

    private let episode = Item(
        id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
        externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 3_600_000)
    )

    private let parent = MarginPacketIdentity(packageDigest: String(repeating: "a", count: 64), packageScopedId: "a-1")
    private var link: MarginReplyLink { .replying(to: parent, parentConversationId: nil) }

    private final class Audio: AudioPlaybackClient {
        var mediaTimeMs: Int? = 300_000
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws {}
        func play(targetId: String, from charOffset: Int) throws {}
        func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { self.mediaTimeMs = mediaTimeMs }
        func currentPlaybackPosition() -> PlaybackPosition? {
            mediaTimeMs.map { PlaybackPosition(mediaTimeMs: $0, durationMs: 3_600_000, anchorConfidence: .mediaTime) }
        }
        func currentCharOffset() -> Int? { nil }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func pause() throws {}
    }

    private func engine() throws -> (SessionEngine, InMemorySessionRepository) {
        let repository = InMemorySessionRepository(items: [episode.id: episode])
        let engine = SessionEngine(profile: profile, repository: repository, audio: Audio())
        _ = try engine.startSession(itemId: episode.id)
        return (engine, repository)
    }

    private func margins(_ engine: SessionEngine, _ repository: InMemorySessionRepository) throws -> [Interjection] {
        try repository.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id))
            .sorted { $0.createdAt < $1.createdAt }
    }

    func testASpokenReplySavesTheLinkItWasBegunWith() throws {
        let (engine, repository) = try engine()
        _ = try engine.beginInterjection(request: MarginCaptureRequest().replying(to: link))
        _ = try engine.finishInterjection(audioRef: "interjections/reply.m4a")

        let saved = try XCTUnwrap(margins(engine, repository).first)
        XCTAssertEqual(saved.replyTo, link)
    }

    func testAWrittenReplySavesTheLinkItWasBegunWith() throws {
        let (engine, repository) = try engine()
        let capture = try engine.beginWrittenInterjection(replyTo: link)
        XCTAssertEqual(capture.replyTo, link)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "I disagree.")

        XCTAssertEqual(try margins(engine, repository).first?.replyTo, link)
    }

    func testAnOrdinaryMarginCarriesNoLink() throws {
        let (engine, repository) = try engine()
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/plain.m4a")
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Plain note.")

        XCTAssertEqual(try margins(engine, repository).map(\.replyTo), [nil, nil])
    }

    func testACancelledReplyDoesNotMakeTheNextMarginAReply() throws {
        let (engine, repository) = try engine()
        _ = try engine.beginInterjection(request: MarginCaptureRequest().replying(to: link))
        _ = try engine.cancelInterjection()

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/after-cancel.m4a")

        XCTAssertEqual(try margins(engine, repository).map(\.replyTo), [nil])
    }

    func testAReplyThenAnOrdinaryMarginKeepsTheLinkOnTheReplyOnly() throws {
        let (engine, repository) = try engine()
        _ = try engine.beginInterjection(request: MarginCaptureRequest().replying(to: link))
        _ = try engine.finishInterjection(audioRef: "interjections/reply.m4a")
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/plain.m4a")

        XCTAssertEqual(try margins(engine, repository).map(\.replyTo), [link, nil])
    }

    // The listener switches a Margin between reply and independent (#473, owner 2026-10-25).

    func testSwitchingARecordingToIndependentSavesNoLinkAndBackSavesIt() throws {
        let (engine, repository) = try engine()
        _ = try engine.beginInterjection(request: MarginCaptureRequest().replying(to: link))
        engine.changeReplyOfCurrentCapture(to: nil)
        _ = try engine.finishInterjection(audioRef: "interjections/independent.m4a")
        _ = try engine.beginInterjection()
        engine.changeReplyOfCurrentCapture(to: link) // the compact controls begin without a link
        _ = try engine.finishInterjection(audioRef: "interjections/reply.m4a")

        XCTAssertEqual(try margins(engine, repository).map(\.replyTo), [nil, link])
    }

    func testSwitchingAWrittenMarginChangesWhatItSaves() throws {
        let (engine, repository) = try engine()
        let capture = try engine.beginWrittenInterjection(replyTo: link)
        engine.changeReplyOfCurrentCapture(to: nil)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Actually my own thought.")

        XCTAssertEqual(try margins(engine, repository).first?.replyTo, nil)
    }
}

/// The choice a listener made on a written Margin is what its journal keeps (#473): switching to independent
/// has to survive the app being closed before Save.
final class WrittenCaptureReplyChoiceTests: XCTestCase {
    private let link = MarginReplyLink.replying(
        to: MarginPacketIdentity(packageDigest: String(repeating: "b", count: 64), packageScopedId: "b-1"), parentConversationId: nil)

    private var capture: WrittenInterjectionCapture {
        WrittenInterjectionCapture(
            id: "c", sessionId: "s", itemId: "i", targetType: .item, targetId: "i",
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            roughPercent: 5, wasPlaying: true, replyTo: link
        )
    }

    func testReplyingChangesOnlyTheLink() {
        let independent = capture.replying(to: nil)
        XCTAssertNil(independent.replyTo)
        XCTAssertEqual(independent.replying(to: link), capture)
    }

    func testAnIndependentChoiceIsWhatTheJournalRestores() {
        let record = WrittenMarginDraftRecord(capture: capture.replying(to: nil), text: "t", updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertNil(record.capture.replyTo)
        let kept = WrittenMarginDraftRecord(capture: capture, text: "t", updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(kept.capture.replyTo, link)
    }
}
