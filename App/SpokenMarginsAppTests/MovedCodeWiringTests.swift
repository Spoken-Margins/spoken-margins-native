import XCTest
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #1894: code moved from the app into SessionKit is tested there, on its own. These tests cover the app's side:
/// the arguments the model passes in, and the calls it makes, so a swapped argument or a dropped call fails here.
@MainActor
final class MovedCodeWiringTests: XCTestCase {
    private var voicePreferences = VoicePreferencesSnapshot.capture()
    private var temporaryURLs: [URL] = []

    override func setUp() {
        super.setUp()
        voicePreferences = VoicePreferencesSnapshot.capture()
    }

    override func tearDown() {
        voicePreferences.restore()
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    // MARK: loadItemDetail passes the snapshot and the model's placement passes to ItemDetailLoader

    /// `ItemDetailLoaderTests` calls the loader with arguments it writes itself. Swapping the two snapshot arguments in
    /// `loadItemDetail`, passing nil for either, or passing a fresh `SharedMarginPlacementPasses()` changes the results below.
    func testLoadItemDetailPassesTheSnapshotsItemAndSessionAndTheModelsPlacementPasses() throws {
        let databaseURL = try makeDirectory("item-detail-wiring").appendingPathComponent("library.sqlite")
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: UnavailableSourceTranscriptionClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try seedTwoItems(store)

        // The snapshot's session belongs to another item: it must not select this item's older session.
        model.snapshot.itemId = "wiring-B"
        model.snapshot.sessionId = "wiring-A-old"
        XCTAssertEqual(try model.loadItemDetail(id: "wiring-A", store: store).interjections.map(\.id), ["note-wiring-A-new"])

        // The snapshot is for this item and names its older session: that session is the one shown.
        model.snapshot.itemId = "wiring-A"
        model.snapshot.sessionId = "wiring-A-old"
        let older = try model.loadItemDetail(id: "wiring-A", store: store)
        XCTAssertEqual(older.interjections.map(\.id), ["note-wiring-A-old"])
        XCTAssertEqual(older.sessions.map(\.id), ["wiring-A-new", "wiring-A-old"])

        // No snapshot session: the newest.
        model.snapshot.sessionId = nil
        XCTAssertEqual(try model.loadItemDetail(id: "wiring-A", store: store).interjections.map(\.id), ["note-wiring-A-new"])

        // The placement passes are the model's: a pass begun on the model shows on the loaded item. The pass is read
        // in the same turn it begins, before its task runs and ends it.
        let file = try makeDirectory("item-detail-wiring-audio").appendingPathComponent("episode.mp3")
        try Data(repeating: 1, count: 64).write(to: file)
        let item = try store.loadItem(id: "wiring-A")
        XCTAssertTrue(model.importedPodcastPlacement.scheduleTransientTranscript(for: item, localSourceURL: file))
        let modelsPass = try XCTUnwrap(model.sharedMarginPlacementPasses.pass(itemId: "wiring-A"))
        XCTAssertEqual(try model.loadItemDetail(id: "wiring-A", store: store).sharedMarginPlacement, modelsPass)
        XCTAssertNil(try model.loadItemDetail(id: "wiring-B", store: store).sharedMarginPlacement, "a pass belongs to its item")
    }

    // MARK: the real ConnectivityMonitor

    /// `PendingHandoffNetworkRetryTests` runs against `ManualConnectivity`, a copy of this behaviour. This is the real class.
    func testTheRealMonitorTellsAnObserverAddedAfterAReportTheCurrentTransportAtOnce() {
        let monitor = ConnectivityMonitor()
        var early: [PodcastNetworkTransport] = []
        monitor.addObserver { early.append($0) }
        XCTAssertEqual(early, [], "nothing has been reported, so there is nothing to replay and no guess is made")

        monitor.update(transport: .cellular, isOffline: false)
        XCTAssertEqual(early, [.cellular])

        var late: [PodcastNetworkTransport] = []
        let lateID = monitor.addObserver { late.append($0) }
        XCTAssertEqual(late, [.cellular], "an observer added after a report hears the current transport at once")

        monitor.update(transport: .unavailable, isOffline: true)
        XCTAssertEqual(late, [.cellular, .unavailable])
        XCTAssertEqual(early, [.cellular, .unavailable])

        monitor.removeObserver(lateID)
        monitor.update(transport: .wifi, isOffline: false)
        XCTAssertEqual(late, [.cellular, .unavailable], "a removed observer hears nothing more")
        XCTAssertEqual(early.last, .wifi)
    }

    // MARK: a waiting link is imported when the network returns

    /// The retry closure in `noteSourceLinkDrain` calls `importPendingSourceLinkHandoffs`. Driving the model's own
    /// monitor offline and then online must run the import again for the link that was waiting.
    func testALinkWaitingForTheNetworkIsImportedAgainWhenTheConnectionReturns() async throws {
        let directory = try makeDirectory("waiting-link")
        let handoffStore = SourceLinkHandoffStore(baseDirectory: directory)
        try handoffStore.save(SourceLinkHandoff(
            id: "payload-waiting-link",
            inputURL: "https://example.com/offline-episode",
            sourceSurface: "share_sheet",
            startSession: false
        ))
        let resolver = OfflineLinkResolver()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: handoffStore,
            browserTextHandoffStore: Gate5BrowserTextHandoffStore(baseDirectory: directory.appendingPathComponent("browser-text")),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: directory.appendingPathComponent("library.sqlite")
        )

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the link to be left waiting") {
            model.sourceLinksWaitingForNetwork == 1 && !model.isImportingPendingSourceLinkHandoffs
        }
        XCTAssertEqual(resolver.callCount, 1)
        XCTAssertEqual(try handoffStore.pendingPayloadIDs(), ["payload-waiting-link"], "a connection failure keeps the link pending")

        // Starting the monitor reports the real network once; let that land so it can't fall between the updates below.
        try await waitFor("the monitor's first report") { model.connectivity.hasReported }
        let callsBeforeOffline = resolver.callCount
        model.connectivity.update(transport: .unavailable, isOffline: true)
        XCTAssertEqual(resolver.callCount, callsBeforeOffline, "going offline retries nothing")
        model.connectivity.update(transport: .wifi, isOffline: false)

        try await waitFor("the import to run again") { resolver.callCount > callsBeforeOffline }
        try await waitFor("the retried drain to finish") { !model.isImportingPendingSourceLinkHandoffs }
    }

    // MARK: starting a Margin stops queued speech

    /// `StreamingSpeechQueueTests` calls `pauseForInterjection` itself. This starts the Margin through the model.
    func testStartingAMarginThroughTheModelStopsQueuedStreamedSpeech() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()
        let speech = StopCountingSpeechClient()
        model.streamingSpeechQueue.configureSpeechClient(speech)
        model.streamingSpeechQueue.enqueue(["A streamed response sentence."], turnId: "turn-wiring")
        try await waitFor("the queue to speak") { speech.playCount > 0 }
        let stopsBeforeMargin = speech.stopCount

        model.beginInterjection()

        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(speech.stopCount, stopsBeforeMargin + 1, "starting a Margin stops the speech the queue is driving")
        XCTAssertTrue(model.streamingSpeechQueue.isPausedForInterjection, "paused, not cleared")
        XCTAssertEqual(model.streamingSpeechQueue.pendingCount, 1, "the interrupted sentence waits to be spoken again")
        model.cancelInterjection()
        model.streamingSpeechQueue.stopAndClear()
    }

    // MARK: Fixtures

    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    /// Items A and B. A has a newer and an older session, B has one; every session has one Margin.
    private func seedTwoItems(_ store: SQLiteSessionStore) throws {
        for id in ["wiring-A", "wiring-B"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "One.\n\nTwo.", externalReference: nil, status: "Ready"))
        }
        for (id, itemID, time) in [("wiring-A-new", "wiring-A", 200.0), ("wiring-B-session", "wiring-B", 300.0), ("wiring-A-old", "wiring-A", 100.0)] {
            try store.saveSession(Session(
                id: id, itemId: itemID,
                createdAt: Date(timeIntervalSince1970: time), updatedAt: Date(timeIntervalSince1970: time),
                status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: itemID, position: Position(), completionPercent: 0, playbackRate: 1
            ))
            try store.saveInterjection(Interjection(
                id: "note-\(id)", itemId: itemID, sessionId: id, targetType: .item, targetId: itemID,
                createdAt: Date(timeIntervalSince1970: time), roughPercent: 0,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
                audioPath: nil, audioStatus: "not_recorded", transcriptionStatus: "transcribed",
                transcript: id, cleanedTranscript: nil, displayText: nil, status: "active"
            ))
        }
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for \(description).") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct UnavailableSourceTranscriptionClient: SourceTranscriptionClient {
    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_transcription_disabled_for_test")
    }
}

/// A resolver that is always offline, and counts how many times the model asked it.
private final class OfflineLinkResolver: LinkResolutionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        lock.withLock { calls += 1 }
        throw URLError(.notConnectedToInternet)
    }
}

/// The speech client behind the streaming queue, counting plays and stops.
private final class StopCountingSpeechClient: AudioPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    private var plays = 0
    var stopCount: Int { lock.withLock { stops } }
    var playCount: Int { lock.withLock { plays } }

    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { lock.withLock { plays += 1 } }
    func pause() throws {}
    func stop() throws { lock.withLock { stops += 1 } }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .pending }
}
