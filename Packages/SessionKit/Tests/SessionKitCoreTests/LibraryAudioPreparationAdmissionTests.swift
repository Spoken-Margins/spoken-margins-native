import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #883: the Library said "45 queued" for audio preparation with about seven items unfinished. Automatic
/// preparation took every item that has text, so a podcast's transcript was queued to be read aloud, and a
/// trashed item kept its jobs. One rule now says what belongs, tested against a real store.
final class LibraryAudioPreparationAdmissionTests: XCTestCase {
    private var directory: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "admission-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheQueueKeepsOnlyJobsForUnfinishedNarratedTextThatIsStillInTheLibrary() throws {
        try seedLibrary()
        let queued = try jobsStillQueued()

        XCTAssertEqual(
            Set(queued.map(\.id)),
            ["unfinished-article", "unfinished-pdf", "unfinished-opening-buffer", "finished-but-asked-for"],
            "unfinished text, plus a request the listener made for a finished item"
        )
        XCTAssertEqual(Set(queued.map(\.itemId)).count, 3, "three items are queued, not four jobs")
    }

    func testFinishedItemsDropTheirAutomaticJobsWhoeverFinishedThem() throws {
        try seedLibrary()
        let stale = try staleJobIds()

        XCTAssertTrue(stale.contains("played-to-the-end-automatic"), "played to the end")
        XCTAssertTrue(stale.contains("played-to-the-end-buffer"), "played to the end, opening buffer")
        XCTAssertTrue(stale.contains("marked-finished-automatic"), "marked finished without playing")
        XCTAssertFalse(stale.contains("finished-but-asked-for"), "an explicit Make available offline request stays")
    }

    func testAPodcastTranscriptIsNeverQueuedToBeReadAloud() throws {
        try seedLibrary()
        let stale = try staleJobIds()

        XCTAssertTrue(stale.contains("podcast-file-automatic"))
        XCTAssertTrue(stale.contains("podcast-stream-buffer"))
        let podcast = try store.loadItem(id: "podcast-file")
        XCTAssertFalse(LibraryAudioPreparationAdmission.admitsAutomatically(podcast, sessions: []))
        XCTAssertTrue(LibraryAudioPreparationAdmission.playsItsOwnAudio(try store.loadItem(id: "podcast-stream")))
        XCTAssertFalse(LibraryAudioPreparationAdmission.playsItsOwnAudio(try store.loadItem(id: "unfinished-pdf")))
    }

    func testTrashedAndMissingItemsDropEveryJobIncludingExplicitOnes() throws {
        try seedLibrary()
        let stale = try staleJobIds()

        XCTAssertTrue(stale.contains("trashed-automatic"))
        XCTAssertTrue(stale.contains("trashed-asked-for"), "deleting an item drops its jobs")
        XCTAssertTrue(stale.contains("orphan-automatic"), "an item that isn't in the store at all")
        XCTAssertTrue(stale.contains("orphan-asked-for"))

        // The same answer when the caller hands over the trashed item itself, not just leaves it out.
        let withTrashed = LibraryAudioPreparationAdmission.staleJobIds(
            try store.loadAudioPreparationJobs(),
            items: try store.listItems(includeDeleted: true),
            sessionsByItemId: [:]
        )
        XCTAssertTrue(withTrashed.contains("trashed-automatic"))
        XCTAssertTrue(withTrashed.contains("trashed-asked-for"))
    }

    func testARestoredItemIsAdmittedAgain() throws {
        try seedLibrary()
        try store.restoreItem(id: "trashed-article")
        let restored = try store.loadItem(id: "trashed-article")

        XCTAssertTrue(LibraryAudioPreparationAdmission.admitsAutomatically(restored, sessions: []))
    }

    func testNeighbouringItemsTableForTheAdmissionRule() {
        func item(_ text: String?, mediaType: String = "text", media: ItemMedia? = nil, finishedAt: Date? = nil, deletedAt: Date? = nil) -> Item {
            var made = Item(
                id: "i", title: "T", mediaType: mediaType, text: text, externalReference: nil, status: "ready",
                media: media, deletedAt: deletedAt
            )
            made.sourceCompletedAt = finishedAt
            return made
        }
        let started = [Session(
            id: "s", itemId: "i", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
            currentTargetId: "i", position: Position(charOffset: 5), completionPercent: 98, playbackRate: 1
        )]
        var atTheEnd = started
        atTheEnd[0].completionPercent = 99

        let rows: [(name: String, item: Item, sessions: [Session], admitted: Bool)] = [
            ("plain article", item("Some words."), [], true),
            ("started, 98 percent", item("Some words."), started, true),
            ("99 percent counts as finished", item("Some words."), atTheEnd, false),
            ("finished by the listener", item("Some words.", finishedAt: Date()), [], false),
            ("pdf with text", item("Some words.", mediaType: "pdf"), [], true),
            ("prerendered narration", item("Some words.", media: ItemMedia(sourceType: .generatedTTSPrerendered, url: "file:///n.m4a")), [], true),
            ("realtime narration", item("Some words.", media: ItemMedia(sourceType: .generatedTTSRealtime)), [], true),
            ("podcast file", item("Transcript.", media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///p.mp3")), [], false),
            ("podcast stream", item("Transcript.", media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/p.mp3")), [], false),
            ("browser-owned media", item("Transcript.", media: ItemMedia(sourceType: .browserOwnedMedia)), [], false),
            ("browser-owned media type", item("Transcript.", mediaType: TargetType.browserOwnedMedia.rawValue), [], false),
            ("trashed", item("Some words.", deletedAt: Date()), [], false),
        ]
        for row in rows {
            XCTAssertEqual(LibraryAudioPreparationAdmission.admitsAutomatically(row.item, sessions: row.sessions), row.admitted, row.name)
        }
    }

    // MARK: - Fixture

    private func jobsStillQueued() throws -> [AudioPreparationJob] {
        let stale = Set(try staleJobIds())
        return try store.loadAudioPreparationJobs().filter { !$0.isCancelled && !stale.contains($0.id) }
    }

    private func staleJobIds() throws -> [String] {
        let sessions = Dictionary(grouping: try store.loadSessions(), by: \.itemId)
        return LibraryAudioPreparationAdmission.staleJobIds(
            try store.loadAudioPreparationJobs(), items: try store.listItems(), sessionsByItemId: sessions
        )
    }

    private func seedLibrary() throws {
        func article(_ id: String, mediaType: String = "text", media: ItemMedia? = nil, finishedAt: Date? = nil) -> Item {
            var made = Item(
                id: id, title: id, mediaType: mediaType, text: "Words to read aloud for \(id).", externalReference: nil, status: "ready",
                media: media, createdAt: Date(timeIntervalSince1970: 1_000)
            )
            made.sourceCompletedAt = finishedAt
            return made
        }
        func job(_ id: String, _ itemId: String, _ policy: PreparationJobPolicy, buffer: Bool = false) -> AudioPreparationJob {
            AudioPreparationJob(id: id, itemId: itemId, manifestId: "manifest-\(id)", policy: policy, maximumChunkCount: buffer ? 2 : nil)
        }
        try store.saveItem(article("unfinished"))
        try store.saveItem(article("unfinished-pdf", mediaType: "pdf"))
        try store.saveItem(article("played-to-the-end"))
        try store.saveItem(article("marked-finished", finishedAt: Date(timeIntervalSince1970: 2_000)))
        try store.saveItem(article("finished-asked"))
        try store.saveItem(article("podcast-file", media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///episode.mp3")))
        try store.saveItem(article("podcast-stream", media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3")))
        try store.saveItem(article("trashed-article"))
        try store.moveItemToTrash(id: "trashed-article")
        try store.saveSession(Session(
            id: "played", itemId: "played-to-the-end", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
            currentTargetId: "played-to-the-end", position: Position(charOffset: 30), completionPercent: 100, playbackRate: 1
        ))
        try store.saveSession(Session(
            id: "asked", itemId: "finished-asked", status: "finished", phase: .finished, currentTargetType: .itemTextTTS,
            currentTargetId: "finished-asked", position: Position(charOffset: 30), completionPercent: 100, playbackRate: 1
        ))

        // Jobs are named for the item they test; "unfinished-article" is the unfinished item's While Charging job.
        try store.saveAudioPreparationJob(job("unfinished-article", "unfinished", .whileCharging))
        try store.saveAudioPreparationJob(job("unfinished-opening-buffer", "unfinished", .demandWindow, buffer: true))
        try store.saveAudioPreparationJob(job("unfinished-pdf", "unfinished-pdf", .whileCharging))
        try store.saveAudioPreparationJob(job("played-to-the-end-automatic", "played-to-the-end", .whileCharging))
        try store.saveAudioPreparationJob(job("played-to-the-end-buffer", "played-to-the-end", .demandWindow, buffer: true))
        try store.saveAudioPreparationJob(job("marked-finished-automatic", "marked-finished", .whileCharging))
        try store.saveAudioPreparationJob(job("finished-but-asked-for", "finished-asked", .explicit))
        try store.saveAudioPreparationJob(job("podcast-file-automatic", "podcast-file", .whileCharging))
        try store.saveAudioPreparationJob(job("podcast-stream-buffer", "podcast-stream", .demandWindow, buffer: true))
        try store.saveAudioPreparationJob(job("trashed-automatic", "trashed-article", .whileCharging))
        try store.saveAudioPreparationJob(job("trashed-asked-for", "trashed-article", .explicit))
        try store.saveAudioPreparationJob(job("orphan-automatic", "no-such-item", .whileCharging))
        try store.saveAudioPreparationJob(job("orphan-asked-for", "no-such-item", .explicit))
    }
}
