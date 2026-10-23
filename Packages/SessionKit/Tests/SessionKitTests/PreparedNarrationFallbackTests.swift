import Foundation
import XCTest
@testable import SessionKit
#if os(macOS) && canImport(AVFoundation)
import AVFoundation
@testable import SessionKitAudio
#endif

/// #237: the rules behind reading an article's text when its rendered narration can't be played,
/// and behind never evicting a file an item still points to.
final class PreparedNarrationFallbackTests: XCTestCase {
    private func article(media: ItemMedia?, mediaType: String = "text") -> Item {
        Item(
            id: "item-article", title: "Article", mediaType: mediaType,
            text: "First sentence. Second sentence.", externalReference: nil, status: "ready", media: media
        )
    }

    private func narration(_ url: URL) -> ItemMedia {
        ItemMedia(sourceType: .generatedTTSPrerendered, url: url.absoluteString, durationMs: 2_300, nativeMediaId: url.absoluteString)
    }

    private func mediaSession(targetId: String) -> Session {
        Session(
            id: "session", itemId: "item-article", status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: targetId,
            position: Position(charOffset: 0, mediaTimeMs: 1_650), completionPercent: 70, playbackRate: 1
        )
    }

    func testOnlyArticlesWithTextCanReadTheirTextInstead() {
        let file = URL(fileURLWithPath: "/tmp/narration.m4a")
        let session = mediaSession(targetId: file.absoluteString)
        XCTAssertTrue(PreparedNarrationFallback.canReadText(instead: session, item: article(media: narration(file))))
        XCTAssertTrue(PreparedNarrationFallback.canReadText(instead: session, item: article(media: nil)),
                      "media already cleared, session still on the file")
        XCTAssertFalse(PreparedNarrationFallback.canReadText(
            instead: session, item: article(media: ItemMedia(sourceType: .nativeMediaFile, url: file.absoluteString))))
        XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session, item: article(media: nil, mediaType: "audiobook")))
        XCTAssertFalse(PreparedNarrationFallback.canReadText(
            instead: mediaSession(targetId: "https://example.com/episode.mp3"), item: article(media: nil)))
        var textless = article(media: narration(file))
        textless.text = "  "
        XCTAssertFalse(PreparedNarrationFallback.canReadText(instead: session, item: textless))
    }

    func testLiveSpeechSessionResumesAtTheTextTheNarrationHadReached() {
        let timeline = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
            MediaTimelineSegment(id: "2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence.")
        ], chapters: [], durationMs: 2_300)
        let item = article(media: nil)
        let reading = PreparedNarrationFallback.liveSpeechSession(
            from: mediaSession(targetId: "file:///tmp/narration.m4a"), item: item, timeline: timeline
        )
        XCTAssertEqual(reading.currentTargetType, .itemTextTTS)
        XCTAssertEqual(reading.currentTargetId, item.id)
        // Halfway through "Second sentence." is character 24, inside "sentence."; reading starts at its first letter (#2128).
        XCTAssertEqual(reading.position.charOffset, 23)
        XCTAssertNil(reading.position.mediaTimeMs)
        XCTAssertEqual(reading.completionPercent, 71)
    }

    func testEvictionDetachesNarrationButKeepsAFileAnItemPlaysAsItsOnlyAudio() {
        let file = URL(fileURLWithPath: "/tmp/PreparedSupertonicAudio/item-article-abc.m4a")
        let other = article(media: nil)
        XCTAssertEqual(PreparedNarrationFallback.release(file, from: [other]), .unreferenced)

        let narrated = article(media: narration(file))
        var detached = narrated
        detached.media = nil
        XCTAssertEqual(PreparedNarrationFallback.release(file, from: [narrated, other]), .detach([detached]))

        let owned = article(media: ItemMedia(sourceType: .nativeMediaFile, url: file.absoluteString))
        XCTAssertEqual(PreparedNarrationFallback.release(file, from: [narrated, owned]), .keep)
    }

    func testEvictionRecognisesAnItemSavedUnderAnOlderAppContainer() {
        let before = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/AAAA/Library/Application Support/PreparedSupertonicAudio/item-article-abc.m4a")
        let after = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/BBBB/Library/Application Support/PreparedSupertonicAudio/item-article-abc.m4a")
        guard case .detach = PreparedNarrationFallback.release(after, from: [article(media: narration(before))]) else {
            return XCTFail("the same file under a moved container is still the item's file")
        }
    }

    func testPrivacySafeFailureDetailKeepsCodesAndDropsNamesAndPaths() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -12842)
        ])
        let described = PlaybackFailureDetail.describe(error)
        XCTAssertEqual(described, "The operation could not be completed [AVFoundationErrorDomain -11800 < NSOSStatusErrorDomain -12842]")
        XCTAssertEqual(PlaybackFailureDetail.privacySafe("playback_start_failed:\(described)"),
                       "playback_start_failed:The operation could not be completed [AVFoundationErrorDomain -11800 < NSOSStatusErrorDomain -12842]")

        let leaky = "playback_start_failed:The file “My Private Article.m4a” couldn’t be opened. file:///var/mobile/x/y.m4a /private/var/mobile/z.m4a"
        let safe = PlaybackFailureDetail.privacySafe(leaky)
        XCTAssertFalse(safe.contains("Private"), safe)
        XCTAssertFalse(safe.contains("/var/mobile"), safe)
        XCTAssertTrue(safe.contains("couldn’t be opened"), safe)
        XCTAssertEqual(PlaybackFailureDetail.privacySafe(nil), "none")
    }

    // #279: a path with a space ("Application Support") kept its tail after the redaction.
    func testPrivacySafeFailureDetailRedactsPathsWithSpaces() {
        let failure = "transcription_failed:Error NSFilePath=/var/mobile/Containers/Data/Application/EXAMPLE/Library/Application Support/PreparedSupertonicAudio/item-EXAMPLE.m4a [NSCocoaErrorDomain 4]"
        let safe = PlaybackFailureDetail.privacySafe(failure)
        XCTAssertFalse(safe.contains("EXAMPLE"), safe)
        XCTAssertFalse(safe.contains("Support/"), safe)
        XCTAssertFalse(safe.contains("PreparedSupertonicAudio"), safe)
        XCTAssertTrue(safe.contains("[NSCocoaErrorDomain 4]"), "the error code survives: \(safe)")
        XCTAssertTrue(safe.hasPrefix("transcription_failed:Error NSFilePath="), safe)
    }

    #if os(macOS) && canImport(AVFoundation)
    /// The real player boundary: an unreadable or missing narration file must surface as a start
    /// failure carrying the error's domain and code, so the engine falls back and diagnostics name it.
    func testRealPlayerReportsUnplayableNarrationWithItsErrorChain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "narration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appending(path: "corrupt.m4a")
        try Data(repeating: 0x5A, count: 4_096).write(to: corrupt)
        let missing = directory.appending(path: "missing.m4a")

        for file in [corrupt, missing] {
            let client = AVPlayerStreamPlaybackClient()
            try client.setPlaybackVolume(0)
            defer { try? client.stop() }
            try client.play(targetId: file.absoluteString, fromMediaTimeMs: 1_650)
            var status = client.playbackStartStatus(targetId: file.absoluteString)
            let deadline = Date().addingTimeInterval(8)
            while status == .pending, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                status = client.playbackStartStatus(targetId: file.absoluteString)
            }
            guard case .failed(let message) = status else {
                return XCTFail("\(file.lastPathComponent): expected a start failure, got \(status)")
            }
            XCTAssertTrue(message.contains(" [") && message.contains("Domain "), "\(file.lastPathComponent): \(message)")
            XCTAssertFalse(PlaybackFailureDetail.privacySafe(message).contains(directory.path))
        }
    }
    #endif
}
