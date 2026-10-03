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
        mapsState: ServerFeatureState = .on,
        item: Item? = nil,
        timeline: TranscriptTimeline? = nil,
        hasPublisherChapters: Bool = false,
        previous: CommunityMapUploadRecord? = nil,
        at time: Date? = nil
    ) -> CommunityMapUploadDecision {
        CommunityMapUploadPolicy.decide(
            optedIn: optedIn, mapsState: mapsState, item: item ?? episode(), timeline: timeline ?? fullTranscript(),
            hasPublisherChapters: hasPublisherChapters, previous: previous, now: time ?? now
        )
    }

    private var expectedKey: String { "fb457cfea268232e0b7362946b20514cd6e3d4e3386d293f7eae8a1c9cbf5c73" }

    // MARK: Policy, one test per rule

    func testUploadsWhenEveryRuleHolds() {
        XCTAssertEqual(decide(), .upload(episodeKey: expectedKey))
    }

    func testNothingUploadsWithoutOptIn() {
        XCTAssertEqual(decide(optedIn: false), .skip(.optedOut))
    }

    func testNothingUploadsWhileTheMapsServiceIsOff() {
        XCTAssertEqual(decide(mapsState: .off(.switchedOff)), .skip(.mapsOff))
        XCTAssertEqual(decide(mapsState: .off(.noConfig)), .skip(.mapsOff))
        XCTAssertEqual(decide(mapsState: .off(.staleConfig)), .skip(.mapsOff))
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

    func testAPartialTranscriptMadeForOneMarginDoesNotCount() {
        let window = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "w1", startMs: 540_000, endMs: 570_000, text: "Around the Margin."),
            MediaTimelineSegment(id: "w2", startMs: 570_000, endMs: 599_000, text: "Up to the end."),
        ], chapters: [], durationMs: 600_000)
        XCTAssertEqual(decide(timeline: window), .skip(.partialTranscript))
        // 94% of the episode is not enough; 95% is.
        let short = TranscriptTimeline(segments: [MediaTimelineSegment(id: "a", startMs: 0, endMs: 564_000, text: "Most of it.")], chapters: [], durationMs: 600_000)
        XCTAssertEqual(decide(timeline: short), .skip(.partialTranscript))
        let enough = TranscriptTimeline(segments: [MediaTimelineSegment(id: "a", startMs: 0, endMs: 570_000, text: "Most of it.")], chapters: [], durationMs: 600_000)
        XCTAssertEqual(decide(timeline: enough), .upload(episodeKey: expectedKey))
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
    }

    // MARK: Episode key

    func testEpisodeKeyHashesTheVersionedPrefixAndGUID() {
        XCTAssertEqual(CommunityMapEpisodeKey.key(episodeGUID: "guid-123", enclosureURL: nil), expectedKey)
        XCTAssertEqual(CommunityMapEpisodeKey.key(episodeGUID: "  guid-123\n", enclosureURL: "https://other.example.com/x.mp3"), expectedKey)
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
        let outcome = await uploader.uploadIfEligible(
            item: item, timeline: fullTranscript(), hasPublisherChapters: false, optedIn: true,
            language: "en_US", repository: repository, now: now, mapsState: { .on }
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
                          "MARGIN-PRIVATE-WORDS", "margin-1", "item-episode", "Episode Seven", "The Show", "guid-123"] {
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

        XCTAssertNil(CommunityMapTranscriptUpload.make(episodeKey: expectedKey, durationMs: 10_000, language: "en",
                                                       timeline: TranscriptTimeline(segments: [], chapters: [])))
        XCTAssertNil(CommunityMapTranscriptUpload.make(episodeKey: expectedKey, durationMs: 0, language: "en",
                                                       timeline: fullTranscript()))
    }

    // MARK: Uploader outcomes

    func testOptedOutSendsNothingAndDoesNotEvenAskForTheServerSwitch() async {
        let posted = PostedBodies()
        let uploader = CommunityMapUploader { url, body in await posted.append(url, body); return 202 }
        let asked = PostedBodies()
        let outcome = await uploader.uploadIfEligible(
            item: episode(), timeline: fullTranscript(), hasPublisherChapters: false, optedIn: false,
            language: "en", repository: InMemorySessionRepository(), now: now,
            mapsState: { await asked.append(CommunityMapUploader.transcriptsURL, Data()); return .on }
        )
        XCTAssertEqual(outcome, .skipped(.optedOut))
        let postCount = await posted.bodies.count
        let askCount = await asked.bodies.count
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(askCount, 0)
    }

    func testFailuresAreRecordedAndRetriedADayLaterWhileRefusalsAreNot() async throws {
        let repository = InMemorySessionRepository()
        let statuses = StatusQueue([503, 202])
        let uploader = CommunityMapUploader { _, _ in try await statuses.next() }
        func upload(at time: Date) async -> CommunityMapUploadOutcome {
            await uploader.uploadIfEligible(item: episode(), timeline: fullTranscript(), hasPublisherChapters: false, optedIn: true,
                                            language: "en", repository: repository, now: time, mapsState: { .on })
        }
        let failed = await upload(at: now)
        XCTAssertEqual(failed, .failed("503"))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.state, .failed)
        let tooSoon = await upload(at: now.addingTimeInterval(3_600))
        XCTAssertEqual(tooSoon, .skipped(.retryTooSoon))
        let nextDay = await upload(at: now.addingTimeInterval(86_400))
        XCTAssertEqual(nextDay, .uploaded(status: 202))
        XCTAssertEqual(try repository.loadCommunityMapUpload(episodeKey: expectedKey)?.attempts, 2)
        let later = await upload(at: now.addingTimeInterval(9 * 86_400))
        XCTAssertEqual(later, .skipped(.alreadyUploaded))
        let remaining = await statuses.remaining
        XCTAssertEqual(remaining, 0)

        let refused = InMemorySessionRepository()
        let refusing = CommunityMapUploader { _, _ in 400 }
        let first = await refusing.uploadIfEligible(item: episode(), timeline: fullTranscript(), hasPublisherChapters: false, optedIn: true,
                                                    language: "en", repository: refused, now: now, mapsState: { .on })
        XCTAssertEqual(first, .rejected(status: 400))
        let again = await refusing.uploadIfEligible(item: episode(), timeline: fullTranscript(), hasPublisherChapters: false, optedIn: true,
                                                    language: "en", repository: refused, now: now.addingTimeInterval(30 * 86_400), mapsState: { .on })
        XCTAssertEqual(again, .skipped(.rejectedBefore))

        let offline = CommunityMapUploader { _, _ in throw URLError(.notConnectedToInternet) }
        let lost = await offline.uploadIfEligible(item: episode(), timeline: fullTranscript(), hasPublisherChapters: false, optedIn: true,
                                                  language: "en", repository: InMemorySessionRepository(), now: now, mapsState: { .on })
        XCTAssertEqual(lost, .failed("network"))
        XCTAssertEqual(lost.diagnostic, "failed:network")
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
        XCTAssertNil(try reopened.loadCommunityMapUpload(episodeKey: String(repeating: "0", count: 64)))
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
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

private actor StatusQueue {
    private var statuses: [Int]

    init(_ statuses: [Int]) { self.statuses = statuses }

    var remaining: Int { statuses.count }

    func next() throws -> Int {
        guard !statuses.isEmpty else { throw URLError(.badServerResponse) }
        return statuses.removeFirst()
    }
}
