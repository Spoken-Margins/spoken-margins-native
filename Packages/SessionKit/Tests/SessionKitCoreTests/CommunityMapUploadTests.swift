import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class CommunityMapUploadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Fixtures

    private func episode(
        id: String = "item-episode",
        guid: String? = "guid-123",
        enclosure: String = "https://dts.podtrac.com/redirect.mp3/cdn.example.com/show/episode-7.mp3",
        feed: String? = "https://feeds.example.com/show.xml",
        durationMs: Int? = 600_000
    ) -> Item {
        var item = Item(
            id: id, title: "Episode Seven", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: "https://podcasts.example.com/show/episode-7", status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: enclosure, durationMs: durationMs),
            sourceTitle: "The Show", sourceURL: feed
        )
        item.episodeGUID = guid
        return item
    }

    /// A transcript from 2 s to 598 s of a 600 s episode, one segment a minute.
    private func fullTranscript(durationMs: Int = 600_000) -> TranscriptTimeline {
        let segments = stride(from: 2_000, to: durationMs - 2_000, by: 60_000).map { start in
            MediaTimelineSegment(id: "seg-\(start)", startMs: start, endMs: min(start + 58_000, durationMs - 2_000), text: "Spoken words at \(start).")
        }
        return TranscriptTimeline(segments: segments, chapters: [], durationMs: durationMs)
    }

    private func decide(
        optedIn: Bool = true,
        item: Item? = nil,
        timeline: TranscriptTimeline? = nil,
        hasPublisherChapters: Bool = false,
        previous: CommunityMapUploadRecord? = nil,
        at time: Date? = nil
    ) -> CommunityMapUploadDecision {
        CommunityMapUploadPolicy.decide(
            optedIn: optedIn, item: item ?? episode(), timeline: timeline ?? fullTranscript(),
            hasPublisherChapters: hasPublisherChapters, previous: previous, now: time ?? now
        )
    }

    /// Runs the uploader the way the app does, with each answer it asks for supplied here.
    private func upload(
        _ uploader: CommunityMapUploader,
        item: Item? = nil,
        timeline: TranscriptTimeline? = nil,
        repository: CommunityMapUploadRepository,
        at time: Date? = nil,
        optedIn: @escaping @Sendable () async -> Bool = { true },
        publisherChapters: @escaping @Sendable () async -> Bool? = { false },
        mapsState: @escaping @Sendable () async -> ServerFeatureState = { .on }
    ) async -> CommunityMapUploadOutcome {
        await uploader.uploadIfEligible(
            item: item ?? episode(), timeline: timeline ?? fullTranscript(), language: "en", repository: repository,
            now: time ?? now, optedIn: optedIn, publisherChapters: publisherChapters, mapsState: mapsState
        )
    }

    private var expectedKey: String { "fb457cfea268232e0b7362946b20514cd6e3d4e3386d293f7eae8a1c9cbf5c73" }

    // MARK: Policy, one test per rule

    func testUploadsWhenEveryRuleHolds() {
        XCTAssertEqual(decide(), .upload(episodeKey: expectedKey))
    }

    func testAShortEpisodeWithATimedTranscriptUploads() {
        let short = episode(durationMs: 45_000)
        XCTAssertEqual(decide(item: short, timeline: timed(from: 0, to: 45_000)), .upload(episodeKey: expectedKey))
        // One block of text is still not a timed transcript, however short the episode.
        let block = TranscriptTimeline(segments: [MediaTimelineSegment(id: "all", startMs: 0, endMs: 45_000, text: "All of it.")],
                                       chapters: [], durationMs: 45_000)
        XCTAssertEqual(decide(item: short, timeline: block), .skip(.untimedTranscript))
    }

    func testAnEpisodeClosedForAnUntimedTranscriptCanStillUploadABetterOne() async throws {
        let repository = InMemorySessionRepository()
        let uploader = CommunityMapUploader { _, _ in 202 }
        // A publisher's untimed transcript, held for chapters, then closed when tried again.
        let block = TranscriptTimeline(segments: [MediaTimelineSegment(id: "all", startMs: 0, endMs: 600_000, text: "All of it.")],
                                       chapters: [], durationMs: 600_000)
        try repository.saveCommunityMapUpload(CommunityMapUploadRecord(
            id: expectedKey, itemId: "item-episode", state: .failed, attempts: 1, lastAttemptAt: now, lastOutcome: "failed:chapters_unchecked"
        ))
        let closed = await upload(uploader, timeline: block, repository: repository, at: now.addingTimeInterval(86_400))
        XCTAssertEqual(closed, .skipped(.untimedTranscript))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.state, .rejected)
        // The same transcript again changes nothing.
        let again = await upload(uploader, timeline: block, repository: repository, at: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(again, .skipped(.untimedTranscript))
        // The phone's own timed transcript of the episode still uploads.
        let phone = await upload(uploader, repository: repository, at: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(phone, .uploaded(status: 202))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.state, .uploaded)

        // A server refusal still closes the episode for good.
        let refused = InMemorySessionRepository()
        try refused.saveCommunityMapUpload(CommunityMapUploadRecord(
            id: expectedKey, itemId: "item-episode", state: .rejected, attempts: 1, lastAttemptAt: now, lastOutcome: "rejected:400"
        ))
        let blocked = await upload(uploader, repository: refused, at: now.addingTimeInterval(86_400))
        XCTAssertEqual(blocked, .skipped(.rejectedBefore))
    }

    func testNothingUploadsWithoutOptIn() {
        XCTAssertEqual(decide(optedIn: false), .skip(.optedOut))
    }

    func testNothingUploadsWhileTheMapsServiceIsOffAndTheEpisodeIsTriedAgainADayLater() async throws {
        for state: ServerFeatureState in [.off(.switchedOff), .off(.noConfig), .off(.staleConfig)] {
            let repository = InMemorySessionRepository()
            let posted = PostedBodies()
            let uploader = CommunityMapUploader { url, body in await posted.append(url, body); return 202 }
            let held = await upload(uploader, repository: repository, mapsState: { state })
            XCTAssertEqual(held, .failed("maps_off"))
            XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.state, .failed)
            let postCount = await posted.bodies.count
            XCTAssertEqual(postCount, 0)
            // Kept for the app's daily retry, which sends it once the switch is on.
            let records = try repository.loadCommunityMapUploads()
            XCTAssertEqual(CommunityMapUploadPolicy.dueForRetry(records, now: now.addingTimeInterval(86_400)).map(\.itemId), ["item-episode"])
            let nextDay = await upload(uploader, repository: repository, at: now.addingTimeInterval(86_400))
            XCTAssertEqual(nextDay, .uploaded(status: 202))
        }
    }

    func testOnlyPodcastEpisodesUpload() {
        let article = Item(id: "article", title: "Article", mediaType: "text", text: "Body", externalReference: "https://example.com/a", status: "ready")
        XCTAssertEqual(decide(item: article), .skip(.notPodcastEpisode))
        var localFile = episode()
        localFile.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///Library/episode.mp3", durationMs: 600_000)
        XCTAssertEqual(decide(item: localFile), .skip(.notPodcastEpisode))
        var noFeed = episode(guid: nil, feed: nil)
        noFeed.externalReference = nil
        XCTAssertEqual(decide(item: noFeed), .skip(.notPodcastEpisode))
    }

    func testAPrivateFeedOrEnclosureNeverUploads() {
        XCTAssertEqual(decide(item: episode(feed: "https://www.patreon.com/rss/show?auth=abc")), .skip(.privateLink))
        XCTAssertEqual(decide(item: episode(enclosure: "https://cdn.example.com/premium/episode-7.mp3")), .skip(.privateLink))
        XCTAssertEqual(
            decide(item: episode(enclosure: "https://cdn.example.com/episode-7.mp3?token=0123456789abcdef0123456789abcdef")),
            .skip(.privateLink)
        )
    }

    func testAnEpisodeWhoseFeedIsUnknownNeverUploads() {
        // The audio link alone can look public while the feed it came from is private.
        XCTAssertEqual(decide(item: episode(feed: nil)), .skip(.unverifiedFeed))
        var linkless = episode(feed: nil)
        linkless.externalReference = nil
        XCTAssertEqual(decide(item: linkless), .skip(.unverifiedFeed))
    }

    func testAPartialTranscriptMadeForOneMarginDoesNotCount() {
        let window = timed(from: 540_000, to: 600_000)
        XCTAssertEqual(decide(timeline: window), .skip(.partialTranscript))
        // 94% of the episode is not enough; 95% is.
        XCTAssertEqual(decide(timeline: timed(from: 0, to: 564_000)), .skip(.partialTranscript))
        XCTAssertEqual(decide(timeline: timed(from: 0, to: 570_000)), .upload(episodeKey: expectedKey))
        // A hole in the middle counts as missing even though the ends are covered: 0-100 s and
        // 390-600 s is 310 s of a 600 s episode.
        let holed = TranscriptTimeline(
            segments: timed(from: 0, to: 100_000).segments + timed(from: 390_000, to: 600_000).segments,
            chapters: [], durationMs: 600_000
        )
        XCTAssertEqual(decide(timeline: holed), .skip(.partialTranscript))
    }

    /// Ten-second segments from `start` to `end` of a 600 s episode.
    private func timed(from start: Int, to end: Int) -> TranscriptTimeline {
        let segments = stride(from: start, to: end, by: 10_000).map {
            MediaTimelineSegment(id: "t\($0)", startMs: $0, endMs: min($0 + 10_000, end), text: "Words at \($0).")
        }
        return TranscriptTimeline(segments: segments, chapters: [], durationMs: 600_000)
    }

    func testPausesBetweenTranscribedWordsCountAsCoveredButALongSilenceDoesNot() {
        // How the phone's transcriber times speech: one interval per word, with the pauses
        // between them left out. Here 800 ms of every second.
        let words = TranscriptTimeline(segments: stride(from: 0, to: 600_000, by: 1_000).map {
            MediaTimelineSegment(id: "w\($0)", startMs: $0, endMs: $0 + 800, text: "word")
        }, chapters: [], durationMs: 600_000)
        XCTAssertEqual(CommunityMapUploadPolicy.coverage(of: words, durationMs: 600_000), 1)
        XCTAssertEqual(decide(timeline: words), .upload(episodeKey: expectedKey))
        // A minute with no words at all is still missing: 540 s of 600 s is 90%.
        var silent = words
        silent.segments.removeAll { $0.startMs >= 100_000 && $0.startMs < 160_000 }
        XCTAssertEqual(decide(timeline: silent), .skip(.partialTranscript))
    }

    func testAnEpisodeWhoseFeedOmitsItsLengthIsMeasuredFromTheDownloadedAudio() async throws {
        let item = episode(durationMs: nil)
        XCTAssertEqual(decide(item: item), .skip(.unknownDuration))
        let uploader = CommunityMapUploader { _, _ in 202 }
        let measured = await uploader.uploadIfEligible(
            item: item, timeline: fullTranscript(), language: "und", repository: InMemorySessionRepository(), now: now,
            optedIn: { true }, publisherChapters: { false }, audioDurationMs: { 600_000 }, mapsState: { .on }
        )
        XCTAssertEqual(measured, .uploaded(status: 202))
        // With no file to measure, it waits for a length as before.
        let unmeasured = await upload(uploader, item: item, repository: InMemorySessionRepository())
        XCTAssertEqual(unmeasured, .failed("unknown_duration"))
    }

    func testAPublisherTranscriptStoredAsOneUntimedBlockNeverUploads() {
        // How plain-text and JSON publisher transcripts are attached: the whole text in one segment.
        let block = TranscriptTimeline(segments: [MediaTimelineSegment(id: "all", startMs: 0, endMs: 600_000, text: "The whole episode as text.")],
                                       chapters: [], durationMs: 600_000)
        XCTAssertEqual(decide(timeline: block), .skip(.untimedTranscript))
        // With no duration in the feed, the block runs 0 to 1 ms.
        let noDuration = TranscriptTimeline(segments: [MediaTimelineSegment(id: "all", startMs: 0, endMs: 1, text: "The whole episode as text.")],
                                            chapters: [], durationMs: 1)
        XCTAssertEqual(decide(item: episode(durationMs: 600_000), timeline: noDuration), .skip(.untimedTranscript))
        // A few sparse segments, or a ten-minute silence in the middle, are not a listened transcript either.
        let sparse = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "a", startMs: 0, endMs: 10_000, text: "Start."),
            MediaTimelineSegment(id: "b", startMs: 590_000, endMs: 600_000, text: "End."),
        ], chapters: [], durationMs: 600_000)
        XCTAssertEqual(decide(timeline: sparse), .skip(.untimedTranscript))
        var gapped = timed(from: 0, to: 600_000)
        gapped.segments.removeAll { $0.startMs >= 100_000 && $0.startMs < 410_000 }
        XCTAssertEqual(decide(timeline: gapped), .skip(.untimedTranscript))
        // A JSON transcript whose entries carry no times: each runs from 0 to the end of the episode.
        let untimedEntries = TranscriptTimeline(segments: (1...20).map {
            MediaTimelineSegment(id: "transcript-item-json-\($0)", startMs: 0, endMs: 600_000, text: "Entry \($0).")
        }, chapters: [], durationMs: 600_000)
        XCTAssertEqual(decide(timeline: untimedEntries), .skip(.untimedTranscript))
    }

    func testATranscriptIsMeasuredAgainstTheEpisodesOwnLengthNotItsOwn() async throws {
        // A VTT covering the first ten minutes of an hour-long episode whose feed gave no length:
        // the parser sets the timeline's duration to its last cue, which would look complete.
        let firstTenMinutes = timed(from: 0, to: 600_000)
        XCTAssertEqual(decide(item: episode(durationMs: nil), timeline: firstTenMinutes), .skip(.unknownDuration))
        XCTAssertEqual(decide(item: episode(durationMs: 3_600_000), timeline: firstTenMinutes), .skip(.partialTranscript))

        // Held for a retry once the length is known, not dropped.
        let repository = InMemorySessionRepository()
        let uploader = CommunityMapUploader { _, _ in 202 }
        let held = await upload(uploader, item: episode(durationMs: nil), timeline: firstTenMinutes, repository: repository)
        XCTAssertEqual(held, .failed("unknown_duration"))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.state, .failed)
        let known = await upload(uploader, repository: repository, at: now.addingTimeInterval(86_400))
        XCTAssertEqual(known, .uploaded(status: 202))
    }

    func testAnEpisodeWithPublisherChaptersDoesNotUpload() {
        XCTAssertEqual(decide(hasPublisherChapters: true), .skip(.publisherChapters))
        let publisherMap = ListeningMap(id: "map-item-publisher-podcast_namespace", itemId: "item", overview: "", chapters: [])
        XCTAssertTrue(CommunityMapUploadPolicy.hasPublisherChapters(map: publisherMap, timeline: nil))
        let chaptered = TranscriptTimeline(segments: [], chapters: [
            MediaTimelineChapter(id: "ch-publisher-podcast_namespace-001", title: "Intro", startMs: 0, transcriptSegmentId: "s"),
        ])
        XCTAssertTrue(CommunityMapUploadPolicy.hasPublisherChapters(map: nil, timeline: chaptered))
        let generatedMap = ListeningMap(id: "map-item", itemId: "item", overview: "", chapters: [])
        XCTAssertFalse(CommunityMapUploadPolicy.hasPublisherChapters(map: generatedMap, timeline: fullTranscript()))
    }

    func testAnEpisodeIsUploadedOnceAndRetriedAtMostOnceADay() {
        let uploaded = CommunityMapUploadRecord(id: expectedKey, itemId: "item-episode", state: .uploaded, attempts: 1, lastAttemptAt: now.addingTimeInterval(-90 * 86_400), lastOutcome: "uploaded:202")
        XCTAssertEqual(decide(previous: uploaded), .skip(.alreadyUploaded))
        let rejected = CommunityMapUploadRecord(id: expectedKey, itemId: "item-episode", state: .rejected, attempts: 1, lastAttemptAt: now.addingTimeInterval(-90 * 86_400), lastOutcome: "rejected:400")
        XCTAssertEqual(decide(previous: rejected), .skip(.rejectedBefore))
        let failed = CommunityMapUploadRecord(id: expectedKey, itemId: "item-episode", state: .failed, attempts: 1, lastAttemptAt: now, lastOutcome: "failed:503")
        XCTAssertEqual(decide(previous: failed, at: now.addingTimeInterval(23 * 3_600)), .skip(.retryTooSoon))
        XCTAssertEqual(decide(previous: failed, at: now.addingTimeInterval(24 * 3_600)), .upload(episodeKey: expectedKey))
        XCTAssertEqual(CommunityMapUploadPolicy.dueForRetry([uploaded, rejected, failed], now: now.addingTimeInterval(23 * 3_600)), [])
        XCTAssertEqual(CommunityMapUploadPolicy.dueForRetry([uploaded, rejected, failed], now: now.addingTimeInterval(24 * 3_600)), [failed])
    }

    // MARK: Episode key

    func testEpisodeKeyHashesTheVersionedPrefixAndGUID() {
        XCTAssertEqual(CommunityMapEpisodeKey.key(episodeGUID: "guid-123", enclosureURL: nil), expectedKey)
        XCTAssertEqual(CommunityMapEpisodeKey.key(episodeGUID: "  guid-123\n", enclosureURL: "https://other.example.com/x.mp3"), expectedKey)
    }

    /// With no feed GUID the key hashes the enclosure's file identity under its own `enclosure:` namespace, so
    /// an enclosure never lands on the key of a GUID with the same text. Two installs must agree on every byte
    /// of it, or each makes its own map of the same episode, so the digest is pinned as a literal (sha256 of
    /// the key prefix, `enclosure:` and `cdn.example.com/show/episode-7.mp3`, computed outside the app).
    func testEnclosureKeyIsPinnedToTheNamespaceTheOtherInstallsUse() {
        let enclosure = "https://cdn.example.com/show/episode-7.mp3"
        let key = CommunityMapEpisodeKey.key(episodeGUID: nil, enclosureURL: enclosure)
        XCTAssertEqual(key, "7013f25cbc88f09d1dda36238057be2e8f4636371f48d904e781051385363dd7")
        // The same text as a GUID is a different episode key.
        XCTAssertNotEqual(key, CommunityMapEpisodeKey.key(episodeGUID: "cdn.example.com/show/episode-7.mp3", enclosureURL: nil))
    }

    func testTwoInstallsGetTheSameKeyForTheSameEpisode() throws {
        // Different item ids, different tracking redirects and different feed copies.
        let first = episode(id: "install-a-item", enclosure: "https://dts.podtrac.com/redirect.mp3/cdn.example.com/show/episode-7.mp3?utm=a")
        let second = episode(id: "install-b-item", enclosure: "https://chtbl.com/track/ABC123/cdn.example.com/show/episode-7.mp3", feed: "https://mirror.example.org/show.xml")
        XCTAssertEqual(CommunityMapEpisodeKey.key(for: first), CommunityMapEpisodeKey.key(for: second))

        // With no GUID, the enclosure's file identity decides, so the same holds.
        let firstNoGUID = CommunityMapEpisodeKey.key(for: episode(id: "a", guid: nil, enclosure: "https://dts.podtrac.com/redirect.mp3/cdn.example.com/show/episode-7.mp3"))
        let secondNoGUID = CommunityMapEpisodeKey.key(for: episode(id: "b", guid: nil, enclosure: "https://cdn.example.com/show/episode-7.mp3?ad=1"))
        XCTAssertNotNil(firstNoGUID)
        XCTAssertEqual(firstNoGUID, secondNoGUID)
        XCTAssertNotEqual(firstNoGUID, expectedKey)
        let key = try XCTUnwrap(firstNoGUID)
        XCTAssertTrue(key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }

    // MARK: Request body

    func testRequestBodyHoldsOnlyTheKeyDurationLanguageAndTimedText() async throws {
        let repository = InMemorySessionRepository()
        let item = episode()
        try repository.saveItem(item)
        try repository.saveInterjection(Interjection(
            id: "margin-1", itemId: item.id, sessionId: "session-1", targetType: .item, targetId: item.id,
            createdAt: now, roughPercent: 50,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: "Library/Recordings/margin-1.m4a", audioStatus: "saved", transcriptionStatus: "complete",
            transcript: "MARGIN-PRIVATE-WORDS", cleanedTranscript: nil, displayText: "MARGIN-PRIVATE-WORDS", status: "active"
        ))
        try repository.savePodcastDownload(PodcastDownloadRecord(
            id: "download-1", itemId: item.id, remoteURL: item.media!.url!,
            localRelativePath: "Library/PodcastDownloads/episode-7.mp3", state: .availableOffline, updatedAt: now
        ))
        let posted = PostedBodies()
        let uploader = CommunityMapUploader { url, body in
            await posted.append(url, body)
            return 202
        }
        // A publisher transcript can read out its sponsor's web address.
        var timeline = fullTranscript()
        timeline.segments[0].text = "Sponsored by https://sponsor.example.com/code and www.sponsor.example.com, or sponsor.example.com/deal."
        timeline.segments[1].text = "Follow along on spotify:episode:4rOoJ6Egrf8K2IrywzwOMk."
        let outcome = await uploader.uploadIfEligible(
            item: item, timeline: timeline, language: "en_US", repository: repository, now: now,
            optedIn: { true }, publisherChapters: { false }, mapsState: { .on }
        )
        XCTAssertEqual(outcome, .uploaded(status: 202))
        let bodies = await posted.bodies
        XCTAssertEqual(bodies.count, 1)
        let body = try XCTUnwrap(bodies.first)
        let urls = await posted.urls
        XCTAssertEqual(urls.first, CommunityMapUploader.transcriptsURL)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "episodeKey", "durationMs", "language", "segments"])
        XCTAssertEqual(json["schema"] as? String, "spokenmargins.episode-transcript.v1")
        XCTAssertEqual(json["episodeKey"] as? String, expectedKey)
        XCTAssertEqual(json["durationMs"] as? Int, 600_000)
        XCTAssertEqual(json["language"] as? String, "en-US")
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 10)
        for segment in segments {
            XCTAssertEqual(Set(segment.keys), ["id", "startMs", "endMs", "text"])
        }

        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        for forbidden in ["http", "://", "www.", "feeds.example.com", "cdn.example.com", "podtrac", "Library", ".mp3", ".m4a",
                          "MARGIN-PRIVATE-WORDS", "margin-1", "item-episode", "Episode Seven", "The Show", "guid-123", "sponsor.example", "spotify:", "4rOoJ6Egrf8K2IrywzwOMk"] {
            XCTAssertFalse(text.contains(forbidden), "The upload must not carry \(forbidden)")
        }

        let record = try XCTUnwrap(repository.loadCommunityMapUpload(episodeKey: expectedKey))
        XCTAssertEqual(record.state, .uploaded)
        XCTAssertEqual(record.itemId, item.id)
    }

    func testRequestBodyMeetsTheServersSegmentRules() throws {
        var segments = [
            MediaTimelineSegment(id: "b", startMs: 5_000, endMs: 6_000, text: "second"),
            MediaTimelineSegment(id: "a", startMs: 1_000, endMs: 2_000, text: "first"),
            MediaTimelineSegment(id: "a2", startMs: 1_000, endMs: 3_000, text: "same start"),
            MediaTimelineSegment(id: "blank", startMs: 4_000, endMs: 4_500, text: "   "),
        ]
        var upload = try XCTUnwrap(CommunityMapTranscriptUpload.make(
            episodeKey: expectedKey, durationMs: 10_000, language: "en",
            timeline: TranscriptTimeline(segments: segments, chapters: [])
        ))
        XCTAssertEqual(upload.segments.map(\.id), ["s1", "s2"])
        XCTAssertEqual(upload.segments.map(\.startMs), [1_000, 5_000])
        XCTAssertEqual(upload.segments.first?.text, "first same start")
        XCTAssertEqual(upload.segments.first?.endMs, 3_000)

        // A long transcript is merged into at most 3,000 runs whose starts still increase.
        segments = (0..<7_001).map { MediaTimelineSegment(id: "x\($0)", startMs: $0 * 500, endMs: $0 * 500 + 400, text: "w\($0)") }
        upload = try XCTUnwrap(CommunityMapTranscriptUpload.make(
            episodeKey: expectedKey, durationMs: 3_600_000, language: "zz@bad",
            timeline: TranscriptTimeline(segments: segments, chapters: [])
        ))
        XCTAssertLessThanOrEqual(upload.segments.count, CommunityMapTranscriptUpload.maximumSegments)
        XCTAssertEqual(zip(upload.segments, upload.segments.dropFirst()).filter { $0.startMs >= $1.startMs }.count, 0)
        XCTAssertTrue(upload.segments.allSatisfy { $0.id.range(of: "^[A-Za-z0-9._:-]{1,64}$", options: .regularExpression) != nil })
        XCTAssertEqual(upload.segments.map(\.text).joined(separator: " ").split(separator: " ").count, 7_001)
        XCTAssertEqual(upload.language, "und")

        // Web addresses are cut from the text; a segment that was only a link is dropped.
        upload = try XCTUnwrap(CommunityMapTranscriptUpload.make(
            episodeKey: expectedKey, durationMs: 10_000, language: "en",
            timeline: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "a", startMs: 1_000, endMs: 2_000,
                                     text: "Visit HTTPS://Example.com/promo now, or www.example.org and example.net/deal today. Version 2.5 is out."),
                MediaTimelineSegment(id: "b", startMs: 3_000, endMs: 4_000, text: "  https://example.com  "),
                MediaTimelineSegment(id: "c", startMs: 5_000, endMs: 6_000, text: "Write to podcast:feed or ftp://files.example.com/x"),
                MediaTimelineSegment(id: "d", startMs: 7_000, endMs: 8_000,
                                     text: "Go to BetterHelp.com today or example.co.uk, e.g. Mr. Smith in the U.S. at 3.30."),
                MediaTimelineSegment(id: "e", startMs: 9_000, endMs: 9_500,
                                     text: "Try example.ai or shop.example.dev; a Ph.D. at 2.5x speed, i.e. 1.5x/day."),
                MediaTimelineSegment(id: "f", startMs: 9_600, endMs: 9_900,
                                     text: "Call tel:+15551234567, email hello@example.com or mailto:hi@example.org, open file:/tmp/x. Note: done."),
                MediaTimelineSegment(id: "g", startMs: 9_950, endMs: 9_990,
                                     text: "Visit //192.0.2.1/promo, (//cdn.example.com/x) or 192.0.2.1:8080 and 10.0.0.1/admin; and/or 1.5x."),
                MediaTimelineSegment(id: "h", startMs: 9_991, endMs: 9_999,
                                     text: "请看 例子.中国/优惠 或 例子.中国 和 пример.рф today."),
                MediaTimelineSegment(id: "i", startMs: 9_999, endMs: 10_000,
                                     text: "Listen on spotify:episode:4rOoJ6Egrf8K2IrywzwOMk or at 10:30, note: done."),
            ], chapters: [])
        ))
        XCTAssertEqual(upload.segments.map(\.text), [
            "Visit now, or and today. Version 2.5 is out.",
            "Write to or",
            "Go to today or , e.g. Mr. Smith in the U.S. at 3.30.",
            "Try or ; a Ph.D. at 2.5x speed, i.e. 1.5x/day.",
            "Call email or open Note: done.",
            "Visit ( or and and/or 1.5x.",
            "请看 或 和 today.",
            "Listen on or at 10:30, note: done.",
        ])
        XCTAssertEqual(upload.segments.map(\.startMs), [1_000, 5_000, 7_000, 9_000, 9_600, 9_950, 9_991, 9_999])

        XCTAssertNil(CommunityMapTranscriptUpload.make(episodeKey: expectedKey, durationMs: 10_000, language: "en",
                                                       timeline: TranscriptTimeline(segments: [], chapters: [])))
        XCTAssertNil(CommunityMapTranscriptUpload.make(episodeKey: expectedKey, durationMs: 0, language: "en",
                                                       timeline: fullTranscript()))
    }

    /// The server answers 400 to a body over its limits, and the uploader records a 400 as a permanent
    /// refusal, so a body past a limit must never be built: an episode longer than 48 hours, a segment
    /// ending past 48 hours, and a body over 2 MiB. Each limit also has a row just inside it.
    func testRequestBodyNeverExceedsTheServersLimits() throws {
        let hour = 3_600_000
        // Reports only whether a body was built; a failing assertion would otherwise print the whole body.
        func builds(durationMs: Int, _ timeline: TranscriptTimeline) -> Bool {
            CommunityMapTranscriptUpload.make(episodeKey: expectedKey, durationMs: durationMs, language: "en", timeline: timeline) != nil
        }

        // Episode length: 48 h is the server's largest.
        XCTAssertTrue(builds(durationMs: 48 * hour, fullTranscript(durationMs: 48 * hour)), "a 48 hour episode is within the limit")
        XCTAssertFalse(builds(durationMs: 48 * hour + 1, fullTranscript(durationMs: 48 * hour)), "an episode over 48 hours is never built")

        // A segment's end is held to 48 h, whatever the transcript claims.
        let late = TranscriptTimeline(segments: [MediaTimelineSegment(id: "a", startMs: 1_000, endMs: 200_000_000, text: "runs past the end")], chapters: [])
        let clamped = try XCTUnwrap(CommunityMapTranscriptUpload.make(episodeKey: expectedKey, durationMs: 10_000, language: "en", timeline: late))
        XCTAssertEqual(clamped.segments.map(\.endMs), [48 * hour])

        // Body size: 2 MiB. 400 words a segment, so the segment count decides which side of the limit it lands on.
        func transcript(segments count: Int) -> TranscriptTimeline {
            let words = String(repeating: "word ", count: 400)
            return TranscriptTimeline(segments: (0..<count).map {
                MediaTimelineSegment(id: "h\($0)", startMs: $0 * 1_000, endMs: $0 * 1_000 + 900, text: words)
            }, chapters: [])
        }
        let fits = try XCTUnwrap(CommunityMapTranscriptUpload.make(episodeKey: expectedKey, durationMs: hour, language: "en", timeline: transcript(segments: 900)))
        XCTAssertLessThanOrEqual(try fits.encoded().count, CommunityMapTranscriptUpload.maximumBytes)
        XCTAssertFalse(builds(durationMs: hour, transcript(segments: 1_500)), "a body over 2 MiB is never built")
    }

    // MARK: Uploader outcomes

    func testOptedOutSendsNothingAndDoesNotEvenAskForTheServerSwitch() async {
        let posted = PostedBodies()
        let uploader = CommunityMapUploader { url, body in await posted.append(url, body); return 202 }
        let asked = PostedBodies()
        let outcome = await upload(
            uploader, repository: InMemorySessionRepository(), optedIn: { false },
            publisherChapters: { await asked.append(CommunityMapUploader.transcriptsURL, Data()); return false },
            mapsState: { await asked.append(CommunityMapUploader.transcriptsURL, Data()); return .on }
        )
        XCTAssertEqual(outcome, .skipped(.optedOut))
        let postCount = await posted.bodies.count
        let askCount = await asked.bodies.count
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(askCount, 0)
    }

    func testTurningTheSettingOffWhileTheServerConfigLoadsStopsTheUpload() async throws {
        let repository = InMemorySessionRepository()
        let posted = PostedBodies()
        let uploader = CommunityMapUploader { url, body in await posted.append(url, body); return 202 }
        let setting = OptInSetting()
        let outcome = await upload(
            uploader, repository: repository, optedIn: { await setting.isOn },
            mapsState: { await setting.turnOff(); return .on }
        )
        XCTAssertEqual(outcome, .skipped(.optedOut))
        let postCount = await posted.bodies.count
        XCTAssertEqual(postCount, 0)
        // Only the attempt recorded before the request remains; retries run only while opted in.
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.lastOutcome, "failed:interrupted")
    }

    func testTurningTheSettingOffWhileTheAudioIsReadMakesNoRequest() async throws {
        let repository = InMemorySessionRepository()
        let posted = PostedBodies()
        let asked = PostedBodies()
        let uploader = CommunityMapUploader { url, body in await posted.append(url, body); return 202 }
        let setting = OptInSetting()
        let outcome = await upload(
            uploader, repository: repository, optedIn: { await setting.isOn },
            publisherChapters: { await setting.turnOff(); return false },
            mapsState: { await asked.append(CommunityMapUploader.transcriptsURL, Data()); return .on }
        )
        XCTAssertEqual(outcome, .skipped(.optedOut))
        let askCount = await asked.bodies.count
        let postCount = await posted.bodies.count
        XCTAssertEqual(askCount, 0)
        XCTAssertEqual(postCount, 0)
        XCTAssertNil(try repository.loadCommunityMapUpload(episodeKey: expectedKey))
    }

    func testAnUploadCutOffMidwayIsAlreadyRecordedForRetry() async throws {
        // While the config request or the post is in flight the app can be closed; the record
        // must already exist by then, or the episode is never tried again.
        let repository = InMemorySessionRepository()
        let key = expectedKey
        let seen = RecordSeen()
        let uploader = CommunityMapUploader { _, _ in
            await seen.note(try? repository.loadCommunityMapUpload(episodeKey: key))
            return 202
        }
        let outcome = await upload(uploader, repository: repository, mapsState: {
            await seen.note(try? repository.loadCommunityMapUpload(episodeKey: key))
            return .on
        })
        XCTAssertEqual(outcome, .uploaded(status: 202))
        let midway = await seen.records
        XCTAssertEqual(midway.map(\.state), [.failed, .failed])
        XCTAssertEqual(midway.map(\.lastOutcome), ["failed:interrupted", "failed:interrupted"])
        let final = try XCTUnwrap(repository.loadCommunityMapUpload(episodeKey: expectedKey))
        XCTAssertEqual(final.state, .uploaded)
        XCTAssertEqual(final.attempts, 1)
    }

    func testNothingIsSentWhenTheAttemptCanNotBeRecorded() async {
        // Storage full: an unrecorded attempt would let every launch that day send again.
        let due = CommunityMapUploadRecord(id: expectedKey, itemId: "item-episode", state: .failed, attempts: 1,
                                           lastAttemptAt: now.addingTimeInterval(-2 * 86_400), lastOutcome: "failed:503")
        let posted = PostedBodies()
        let uploader = CommunityMapUploader { url, body in await posted.append(url, body); return 202 }
        let outcome = await upload(uploader, repository: FullStorage(record: due))
        XCTAssertEqual(outcome, .failed("storage"))
        XCTAssertEqual(outcome.diagnostic, "failed:storage")
        let postCount = await posted.bodies.count
        XCTAssertEqual(postCount, 0)
    }

    func testAnEpisodeIsHeldUntilItsAudioCanBeCheckedForEmbeddedChapters() async throws {
        let repository = InMemorySessionRepository()
        let posted = PostedBodies()
        let asked = PostedBodies()
        let uploader = CommunityMapUploader { url, body in await posted.append(url, body); return 202 }
        let unchecked = await upload(
            uploader, repository: repository, publisherChapters: { nil },
            mapsState: { await asked.append(CommunityMapUploader.transcriptsURL, Data()); return .on }
        )
        XCTAssertEqual(unchecked, .failed("chapters_unchecked"))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.state, .failed)
        let askCount = await asked.bodies.count
        XCTAssertEqual(askCount, 0)

        // A day later the file is there and its embedded chapters are found: never sent.
        let chaptered = await upload(uploader, repository: repository, at: now.addingTimeInterval(86_400), publisherChapters: { true })
        XCTAssertEqual(chaptered, .skipped(.publisherChapters))
        let postCount = await posted.bodies.count
        XCTAssertEqual(postCount, 0)
        // The record is closed, so it doesn't come back first in every retry.
        let settled = try XCTUnwrap(repository.loadCommunityMapUpload(episodeKey: expectedKey))
        XCTAssertEqual(settled.state, .rejected)
        XCTAssertEqual(settled.lastOutcome, "skipped:publisher_chapters")
        XCTAssertEqual(CommunityMapUploadPolicy.dueForRetry([settled], now: now.addingTimeInterval(30 * 86_400)), [])
    }

    func testAHeldEpisodeIsLeftAloneAfterAWeekOfTries() async throws {
        let repository = InMemorySessionRepository()
        let uploader = CommunityMapUploader { _, _ in 202 }
        for day in 0..<CommunityMapUploadPolicy.maximumAttempts {
            let held = await upload(uploader, repository: repository, at: now.addingTimeInterval(Double(day) * 86_400), publisherChapters: { nil })
            XCTAssertEqual(held, .failed("chapters_unchecked"))
        }
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.attempts, CommunityMapUploadPolicy.maximumAttempts)
        let eighth = await upload(uploader, repository: repository, at: now.addingTimeInterval(7 * 86_400), publisherChapters: { nil })
        XCTAssertEqual(eighth, .skipped(.tooManyAttempts))
        let records = try repository.loadCommunityMapUploads()
        XCTAssertEqual(records.map(\.state), [.rejected])
        XCTAssertEqual(CommunityMapUploadPolicy.dueForRetry(records, now: now.addingTimeInterval(30 * 86_400)), [])
    }

    func testFailuresAreRecordedAndRetriedADayLaterWhileRefusalsAreNot() async throws {
        let repository = InMemorySessionRepository()
        let statuses = StatusQueue([503, 202])
        let uploader = CommunityMapUploader { _, _ in try await statuses.next() }
        func attempt(at time: Date) async -> CommunityMapUploadOutcome {
            await upload(uploader, repository: repository, at: time)
        }
        let failed = await attempt(at: now)
        XCTAssertEqual(failed, .failed("503"))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.state, .failed)
        let tooSoon = await attempt(at: now.addingTimeInterval(3_600))
        XCTAssertEqual(tooSoon, .skipped(.retryTooSoon))
        let nextDay = await attempt(at: now.addingTimeInterval(86_400))
        XCTAssertEqual(nextDay, .uploaded(status: 202))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.attempts, 2)
        let later = await attempt(at: now.addingTimeInterval(9 * 86_400))
        XCTAssertEqual(later, .skipped(.alreadyUploaded))
        let remaining = await statuses.remaining
        XCTAssertEqual(remaining, 0)

        let refused = InMemorySessionRepository()
        let refusing = CommunityMapUploader { _, _ in 400 }
        let first = await upload(refusing, repository: refused)
        XCTAssertEqual(first, .rejected(status: 400))
        let again = await upload(refusing, repository: refused, at: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(again, .skipped(.rejectedBefore))

        let offline = CommunityMapUploader { _, _ in throw URLError(.notConnectedToInternet) }
        let lost = await upload(offline, repository: InMemorySessionRepository())
        XCTAssertEqual(lost, .failed("network"))
        XCTAssertEqual(lost.diagnostic, "failed:network")
    }

    /// The server's answers, and what the uploader makes of each. 200 means the server already has a map
    /// and 202 that it took the transcript: both are done for good. A 4xx other than 429 says this body
    /// will never be accepted, so it is not sent again. Everything else, including 429 (rate limited) and a
    /// redirect the request does not follow, is tried again a day later. The stored record decides what
    /// happens next, so each row checks the record and when the episode is next due, not only the outcome.
    func testEachServerStatusIsRecordedAsTheOutcomeItMeans() async throws {
        let table: [(status: Int, outcome: CommunityMapUploadOutcome, state: CommunityMapUploadRecord.State)] = [
            (200, .uploaded(status: 200), .uploaded),
            (202, .uploaded(status: 202), .uploaded),
            (301, .failed("301"), .failed),
            (307, .failed("307"), .failed),
            (400, .rejected(status: 400), .rejected),
            (404, .rejected(status: 404), .rejected),
            (413, .rejected(status: 413), .rejected),
            (422, .rejected(status: 422), .rejected),
            (429, .failed("429"), .failed),
            (500, .failed("500"), .failed),
            (503, .failed("503"), .failed)
        ]
        for (status, outcome, state) in table {
            let repository = InMemorySessionRepository()
            let result = await upload(CommunityMapUploader { _, _ in status }, repository: repository)
            XCTAssertEqual(result, outcome, "status \(status)")
            let record = try XCTUnwrap(repository.loadCommunityMapUpload(episodeKey: expectedKey), "status \(status)")
            XCTAssertEqual(record.state, state, "status \(status)")
            let dueNextDay = CommunityMapUploadPolicy.dueForRetry(try repository.loadCommunityMapUploads(), now: now.addingTimeInterval(86_400))
            XCTAssertEqual(dueNextDay.map(\.id), state == .failed ? [expectedKey] : [], "status \(status): due again the next day only when it failed")
        }
    }

    func testARetryWhoseEpisodeGainedAGUIDMovesToTheNewKeyAndClosesTheOldRow() throws {
        let repository = InMemorySessionRepository()
        let oldKey = try XCTUnwrap(CommunityMapEpisodeKey.key(for: episode(guid: nil)))
        let stale = CommunityMapUploadRecord(id: oldKey, itemId: "item-episode", state: .failed, attempts: 2,
                                             lastAttemptAt: now, lastOutcome: "failed:503")
        try repository.saveCommunityMapUpload(stale)
        let later = now.addingTimeInterval(86_400)
        // A reimport filled in the GUID, so the episode's key is now the GUID's.
        XCTAssertTrue(CommunityMapUploadPolicy.prepareRetry(stale, item: episode(), hasTranscript: true, repository: repository, now: later))
        let old = try XCTUnwrap(repository.loadCommunityMapUpload(episodeKey: oldKey))
        XCTAssertEqual(old.state, .rejected)
        XCTAssertEqual(old.lastOutcome, "skipped:key_changed")
        let moved = try XCTUnwrap(repository.loadCommunityMapUpload(episodeKey: expectedKey))
        XCTAssertEqual(moved.state, .failed)
        XCTAssertEqual(moved.attempts, 2)
        XCTAssertEqual(CommunityMapUploadPolicy.dueForRetry(try repository.loadCommunityMapUploads(), now: later).map(\.id), [expectedKey])

        // The new key's own record is kept as it is.
        let uploaded = InMemorySessionRepository()
        let done = CommunityMapUploadRecord(id: expectedKey, itemId: "item-other", state: .uploaded, attempts: 1,
                                            lastAttemptAt: now, lastOutcome: "202")
        try uploaded.saveCommunityMapUpload(done)
        try uploaded.saveCommunityMapUpload(stale)
        XCTAssertTrue(CommunityMapUploadPolicy.prepareRetry(stale, item: episode(), hasTranscript: true, repository: uploaded, now: later))
        XCTAssertEqual(try uploaded.loadCommunityMapUpload(episodeKey: expectedKey), done)
        XCTAssertEqual(try uploaded.loadCommunityMapUpload(episodeKey: oldKey)?.state, .rejected)

        // An unchanged key is simply retried.
        let current = CommunityMapUploadRecord(id: expectedKey, itemId: "item-episode", state: .failed, attempts: 1,
                                               lastAttemptAt: now, lastOutcome: "failed:503")
        let same = InMemorySessionRepository()
        try same.saveCommunityMapUpload(current)
        XCTAssertTrue(CommunityMapUploadPolicy.prepareRetry(current, item: episode(), hasTranscript: true, repository: same, now: later))
        XCTAssertEqual(try same.loadCommunityMapUploads(), [current])
    }

    func testARetryWhoseItemTranscriptOrKeyIsGoneIsClosed() throws {
        let record = CommunityMapUploadRecord(id: expectedKey, itemId: "item-episode", state: .failed, attempts: 1,
                                              lastAttemptAt: now, lastOutcome: "failed:503")
        for (item, hasTranscript) in [(nil, true), (episode(), false), (episode(guid: nil, enclosure: ""), true)] as [(Item?, Bool)] {
            let repository = InMemorySessionRepository()
            try repository.saveCommunityMapUpload(record)
            XCTAssertFalse(CommunityMapUploadPolicy.prepareRetry(record, item: item, hasTranscript: hasTranscript,
                                                                 repository: repository, now: now.addingTimeInterval(86_400)))
            let closed = try XCTUnwrap(repository.loadCommunityMapUpload(episodeKey: expectedKey))
            XCTAssertEqual(closed.state, .rejected)
            XCTAssertEqual(closed.lastOutcome, "skipped:item_gone")
        }
    }

    // MARK: Storage

    func testUploadRecordsSurviveReopeningTheDatabaseWithoutASchemaChange() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "library.sqlite").path
        let record = CommunityMapUploadRecord(id: expectedKey, itemId: "item-episode", state: .failed, attempts: 1,
                                              lastAttemptAt: now, lastOutcome: "failed:503")
        do {
            let store = try SQLiteSessionStore(path: path)
            let before = SQLiteSessionStore.schemaVersion(atPath: path)
            try store.saveCommunityMapUpload(record)
            XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), before)
        }
        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.loadCommunityMapUpload(episodeKey: expectedKey), record)
        XCTAssertEqual(try reopened.loadCommunityMapUploads(), [record])
        XCTAssertNil(try reopened.loadCommunityMapUpload(episodeKey: String(repeating: "0", count: 64)))
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
    }

    func testDeletingOneLibraryCopyKeepsTheEpisodesUploadHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        let item = episode()
        try store.saveItem(item)
        let uploaded = CommunityMapUploadRecord(id: expectedKey, itemId: item.id, state: .uploaded, attempts: 1,
                                                lastAttemptAt: now, lastOutcome: "uploaded:202")
        try store.saveCommunityMapUpload(uploaded)
        try store.deleteItem(id: item.id)
        // Importing the episode again finds it already sent.
        XCTAssertEqual(try store.loadCommunityMapUpload(episodeKey: expectedKey), uploaded)
        XCTAssertEqual(decide(item: episode(id: "reimported"), previous: try store.loadCommunityMapUpload(episodeKey: expectedKey)),
                       .skip(.alreadyUploaded))
    }
}

private actor PostedBodies {
    private(set) var urls: [URL] = []
    private(set) var bodies: [Data] = []

    func append(_ url: URL, _ body: Data) {
        urls.append(url)
        bodies.append(body)
    }
}

/// A store that can read but not write, as when the device's storage is full.
private struct FullStorage: CommunityMapUploadRepository {
    let record: CommunityMapUploadRecord

    func saveCommunityMapUpload(_ record: CommunityMapUploadRecord) throws { throw CocoaError(.fileWriteOutOfSpace) }
    func loadCommunityMapUpload(episodeKey: String) throws -> CommunityMapUploadRecord? { record }
    func loadCommunityMapUploads() throws -> [CommunityMapUploadRecord] { [record] }
}

private actor RecordSeen {
    private(set) var records: [CommunityMapUploadRecord] = []

    func note(_ record: CommunityMapUploadRecord?) {
        if let record { records.append(record) }
    }
}

private actor OptInSetting {
    private(set) var isOn = true

    func turnOff() { isOn = false }
}

private actor StatusQueue {
    private var statuses: [Int]

    init(_ statuses: [Int]) { self.statuses = statuses }

    var remaining: Int { statuses.count }

    func next() throws -> Int {
        guard !statuses.isEmpty else { throw URLError(.badServerResponse) }
        return statuses.removeFirst()
    }
}
