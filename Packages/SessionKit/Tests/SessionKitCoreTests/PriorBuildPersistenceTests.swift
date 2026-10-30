import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

final class PriorBuildPersistenceTests: XCTestCase {
    func testExternalBuild19LibraryOpensAndPreservesBothSessionsAfterReconstruction() throws {
        try checkPriorLibrary(build: 19, schema: 4)
    }

    func testInternalBuild25LibraryOpensAndPreservesBothSessionsAfterReconstruction() throws {
        try checkPriorLibrary(build: 25, schema: 5)
    }

    func testExternalBuild32LibraryOpensAndPreservesBothSessionsAfterReconstruction() throws {
        try checkPriorLibrary(build: 32, schema: 5)
    }

    func testInternalBuild34LibraryOpensAndPreservesBothSessionsAfterReconstruction() throws {
        try checkPriorLibrary(build: 34, schema: 5)
    }

    /// #1900: what Build 34 wrote for a podcast with a saved download and an imported file the listener linked to its
    /// episode is read whole, and a round trip through today's store keeps every field and quarantines nothing.
    func testBuild34PodcastWithADownloadAndALinkedEpisodeIsReadWholeAndSurvivesARewrite() throws {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build34.sqlite")
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let database = temporary.appending(path: "library.sqlite")
        try FileManager.default.copyItem(at: fixture, to: database)
        let store = try SQLiteSessionStore(path: database.path)

        let episode = try store.loadItem(id: "prior-podcast")
        XCTAssertEqual(episode.media?.sourceType, .remoteStream)
        XCTAssertEqual(episode.media?.url, "https://cdn.example.com/prior.mp3")
        XCTAssertEqual(episode.media?.durationMs, 1_800_000)
        XCTAssertEqual(episode.episodeGUID, "guid-prior")
        XCTAssertEqual(episode.showTitle, "The Prior Show")
        XCTAssertEqual(episode.publishedAt, "Tue, 29 Sep 2026 10:00:00 GMT")
        let download = try XCTUnwrap(try store.loadPodcastDownload(itemId: episode.id))
        XCTAssertEqual(download.id, "prior-download")
        XCTAssertEqual(download.state, .availableOffline)
        XCTAssertEqual(download.localRelativePath, "Podcasts/prior.mp3")
        XCTAssertEqual(download.bytesWritten, 28_800_000)
        XCTAssertEqual(try store.loadSession(id: "prior-podcast-session")?.position.mediaTimeMs, 600_000)
        let margin = try XCTUnwrap(try store.loadInterjections(sessionId: "prior-podcast-session").first)
        XCTAssertEqual(margin.id, "prior-podcast-margin")
        XCTAssertEqual(margin.anchor.mediaTimeMs, 600_000)
        let linked = try store.loadItem(id: "prior-linked-file")
        XCTAssertEqual(linked.linkedEpisode, LinkedEpisode(
            guid: "guid-prior", title: "Prior release episode", showTitle: "The Prior Show",
            publishedAt: "Tue, 29 Sep 2026 10:00:00 GMT", pageURL: "https://feeds.example.com/prior",
            enclosureURL: "https://cdn.example.com/prior.mp3", durationMs: 1_800_000))
        XCTAssertEqual(linked.media?.sourceType, .nativeMediaFile)

        try store.saveItem(episode)
        try store.saveItem(linked)
        try store.savePodcastDownload(download)
        let reopened = try SQLiteSessionStore(path: database.path)
        XCTAssertEqual(try reopened.loadItem(id: "prior-podcast"), episode)
        XCTAssertEqual(try reopened.loadItem(id: "prior-linked-file"), linked)
        XCTAssertEqual(try reopened.loadPodcastDownload(itemId: episode.id), download)
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
    }

    /// The fixture is the wire form of a written Margin that older readers rely on. Parsing it and
    /// comparing it with literals only proved the file says what it says (#1048, PERSIST-13), so this
    /// saves a written Margin through the engine and expects it to match the file field for field.
    func testSavingAWrittenMarginWritesWhatTheWireFixtureDeclares() throws {
        let fixture = try TestInputs.url(.contracts, "fixtures/interjections/written-interjection.json")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let audio = try XCTUnwrap(payload["audio"] as? [String: Any])
        XCTAssertEqual(payload["captureKind"] as? String, "written", "the wire value older readers know")
        XCTAssertEqual(audio["status"] as? String, "discarded")
        XCTAssertTrue(audio["path"] is NSNull, "The wire fixture must explicitly carry no audio path.")

        let item = Item(id: "item-written", title: "Written", mediaType: "text", text: "Before and after.", externalReference: nil, status: "ready")
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "written-fixture", displayName: "Written fixture",
                capabilities: ["sync": ["canonical_persistence"], "interjection": ["capture_text_anchor"]]),
            repository: repository)
        _ = try engine.startSession(itemId: item.id)
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "Keep  this exact thought.")
        let saved = try XCTUnwrap(repository.loadInterjections(sessionId: capture.sessionId).first)

        XCTAssertEqual(saved.captureKind?.rawValue, payload["captureKind"] as? String)
        XCTAssertEqual(saved.audioStatus, audio["status"] as? String)
        XCTAssertNil(saved.audioPath)
        XCTAssertEqual(saved.transcript, payload["transcript"] as? String, "the text is kept exactly, double space and all")
        XCTAssertEqual(saved.transcriptionStatus, payload["transcriptionStatus"] as? String)
        XCTAssertEqual(saved.status, payload["status"] as? String)
    }

    private func checkPriorLibrary(build: Int, schema: Int) throws {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build\(build).sqlite")
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let database = temporary.appending(path: "library.sqlite")
        try FileManager.default.copyItem(at: fixture, to: database)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: database.path), schema)
        do {
            let store = try SQLiteSessionStore(path: database.path)
            XCTAssertEqual(try store.loadItem(id: "prior-article").text, "The source must survive an upgrade.")
            XCTAssertEqual(Set(try store.loadSessions(itemId: "prior-article").map(\.id)), ["prior-A", "prior-B"])
            XCTAssertEqual(try store.loadSession(id: "prior-A")?.position.charOffset, 7)
            XCTAssertEqual(try store.loadSession(id: "prior-B")?.position.charOffset, 19)
            for (id, words) in [("prior-A", "ALPHA prior note"), ("prior-B", "BRAVO prior note")] {
                let notes = try store.loadInterjections(sessionId: id)
                XCTAssertEqual(notes.map(\.id), ["shared-note-id"])
                XCTAssertEqual(notes.first?.transcript, words)
                XCTAssertNil(notes.first?.captureKind, "Legacy records without captureKind remain audio semantics.")
            }
            var item = try store.loadItem(id: "prior-article")
            XCTAssertNil(item.sourceCompletedAt)
            item.sourceCompletedAt = Date(timeIntervalSince1970: 1234)
            try store.saveItem(item)
            var resumed = try XCTUnwrap(store.loadSession(id: "prior-A"))
            resumed.position.charOffset = 12
            try store.saveSession(resumed)
            XCTAssertEqual(try store.quarantinedRecordCount(), 0)
        }
        let reopened = try SQLiteSessionStore(path: database.path)
        XCTAssertEqual(try reopened.loadItem(id: "prior-article").sourceCompletedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertEqual(try reopened.loadSession(id: "prior-A")?.position.charOffset, 12)
        XCTAssertEqual(try reopened.loadSession(id: "prior-B")?.position.charOffset, 19)
        XCTAssertEqual(try reopened.loadSession(id: "prior-A")?.playbackRate, 1.5)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "prior-A").first?.transcript, "ALPHA prior note")
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "prior-B").first?.transcript, "BRAVO prior note")
        XCTAssertNil(try reopened.loadInterjections(sessionId: "prior-A").first?.captureKind)
        XCTAssertNil(try reopened.loadInterjections(sessionId: "prior-B").first?.captureKind)
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
    }
}
