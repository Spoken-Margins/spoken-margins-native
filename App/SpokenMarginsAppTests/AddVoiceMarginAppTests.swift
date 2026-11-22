import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4924: Add Voice Margin saves a recording as a spoken Margin by the route Add Margin takes for words, and refuses
/// what can't be one with nothing saved. A stand-in measures the length (no audio is decoded), so each route is tested
/// on its own with a real file, real storage and the real model.
@MainActor
final class AddVoiceMarginAppTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let sampleId = Gate1AppModel.welcomeSampleItemId

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "voice-margin-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        support = root.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return model
    }

    private func recording(_ name: String = "memo.m4a", bytes: Int = 64) throws -> URL {
        let url = root.appending(path: name)
        try Data(repeating: 9, count: bytes).write(to: url)
        return url
    }

    private func add(
        _ url: URL, item: String? = nil, model: Gate1AppModel, files: LiveSessionFileWorker, ms: Int? = 5_000
    ) async throws -> String {
        try await AddVoiceMarginAction.perform(
            audio: url, toItemId: item, in: model, files: files, supportDirectory: support, durationMs: { _ in ms }, now: t0
        )
    }

    /// Every file the action kept under the app's recordings.
    private func keptRecordings() -> [String] {
        let folder = support.appending(path: "SpokenMargins/interjections")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testARunningLiveSessionTakesTheRecordingAsASpokenMargin() async throws {
        let model = makeModel()
        let files = LiveSessionFileWorker(root: root)
        try await files.save(LiveSession(id: "live", kind: .audiobook, title: "Night read", startedAt: t0), generation: 1)
        let name = try await add(try recording(), model: model, files: files)
        XCTAssertEqual(name, "Night read")
        let stored = await files.session(id: "live")
        let margin = try XCTUnwrap(stored?.margins.first)
        XCTAssertTrue(margin.isSpoken)
        XCTAssertEqual(margin.durationMs, 5_000)
        XCTAssertEqual(margin.markedAt, t0)
        XCTAssertTrue(try XCTUnwrap(margin.audioPath).hasPrefix("SpokenMargins/interjections/shortcut-voice-"))
        XCTAssertEqual(keptRecordings().count, 1)
    }

    func testTheLiveSessionBeatsTheItemInThePlayer() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let files = LiveSessionFileWorker(root: root)
        try await files.save(LiveSession(id: "live", kind: .meeting, title: "", startedAt: t0), generation: 1)
        let name = try await add(try recording(), model: model, files: files)
        XCTAssertEqual(name, "your meeting session")
        let onItem = try XCTUnwrap(model.store).loadInterjections(sessionId: sessionId)
        XCTAssertTrue(onItem.isEmpty, "the item in the player was left alone")
    }

    func testWithNoLiveSessionThePlayersItemTakesItAtThePlaceItHasNowAndKeepsPlaying() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        let files = LiveSessionFileWorker(root: root)
        let name = try await add(try recording(), model: model, files: files)
        XCTAssertFalse(name.isEmpty)
        let saved = try XCTUnwrap(model.store).loadInterjections(sessionId: sessionId)
        let margin = try XCTUnwrap(saved.first)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(margin.itemId, "item-pill")
        XCTAssertEqual(margin.audioStatus, "saved")
        XCTAssertNotEqual(margin.captureKind, .written)
        XCTAssertTrue(try XCTUnwrap(margin.audioPath).hasPrefix("SpokenMargins/interjections/shortcut-voice-"))
        XCTAssertEqual(model.snapshot.status, .playing, "a source that was playing plays on")
        XCTAssertNil(model.writtenMarginDraft, "no draft is left open")
        XCTAssertEqual(keptRecordings().count, 1)
    }

    func testAChosenItemThatIsNotPlayingTakesItAtItsSavedPlaceAndThePlayerCarriesOn() async throws {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: sampleId)
        let sampleSessionId = try XCTUnwrap(model.snapshot.sessionId)
        model.startItem(id: "item-pill")
        let playingSessionId = try XCTUnwrap(model.snapshot.sessionId)
        let store = try XCTUnwrap(model.store)
        var saved = try XCTUnwrap(store.loadSession(id: sampleSessionId))
        saved.position.charOffset = 120
        try store.saveSession(saved)
        let files = LiveSessionFileWorker(root: root)

        _ = try await add(try recording(), item: sampleId, model: model, files: files)

        let margins = try store.loadInterjections(sessionId: sampleSessionId)
        let margin = try XCTUnwrap(margins.first)
        XCTAssertEqual(margins.count, 1)
        XCTAssertEqual(margin.anchor.startChar, 120)
        XCTAssertEqual(margin.audioStatus, "saved")
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(model.snapshot.sessionId, playingSessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertTrue(try store.loadInterjections(sessionId: playingSessionId).isEmpty)
    }

    func testNamingThePlayingItemIsThePlayerCase() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let files = LiveSessionFileWorker(root: root)
        _ = try await add(try recording(), item: "item-pill", model: model, files: files)
        XCTAssertEqual(try XCTUnwrap(model.store).loadInterjections(sessionId: sessionId).count, 1)
        XCTAssertEqual(model.snapshot.status, .playing)
    }

    /// As Add Margin: a chosen item comes first, so the item in the player wins over a running live session when it is the
    /// one chosen.
    func testChoosingThePlayingItemBeatsARunningLiveSession() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let files = LiveSessionFileWorker(root: root)
        try await files.save(LiveSession(id: "live", kind: .audiobook, title: "Night read", startedAt: t0), generation: 1)
        let name = try await add(try recording(), item: "item-pill", model: model, files: files)
        XCTAssertNotEqual(name, "Night read")
        XCTAssertEqual(try XCTUnwrap(model.store).loadInterjections(sessionId: sessionId).count, 1)
        let live = await files.session(id: "live")
        XCTAssertEqual(live?.margins, [])
    }

    func testAnItemNeverStartedIsRefusedAndTheCopyIsRemoved() async throws {
        let model = makeModel()
        model.addSampleItem()
        model.startItem(id: "item-pill")
        let files = LiveSessionFileWorker(root: root)
        do {
            _ = try await add(try recording(), item: sampleId, model: model, files: files)
            XCTFail("An item with no session can't take a Margin.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .itemNotStarted)
        }
        XCTAssertEqual(keptRecordings(), [], "no recording is kept that no Margin names")
    }

    /// The quick route is #4927's rule: nothing runs, so the Margin is kept in a quick session.
    func testNothingRunningKeepsItInAQuickSession() async throws {
        let model = makeModel()
        XCTAssertFalse(model.hasActiveSession)
        let files = LiveSessionFileWorker(root: root)
        let name = try await add(try recording(), model: model, files: files)
        XCTAssertEqual(name, "a quick session in your Library")
        let sessions = await files.allSessions()
        let quick = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(quick.isQuick, true)
        let margin = try XCTUnwrap(quick.margins.first)
        XCTAssertTrue(margin.isSpoken)
        XCTAssertEqual(margin.durationMs, 5_000)
        XCTAssertFalse(model.hasActiveSession, "the player was never started")
    }

    func testEveryRefusalSavesNothingAndKeepsNoFile() async throws {
        let model = makeModel()
        let files = LiveSessionFileWorker(root: root)
        try await files.save(LiveSession(id: "live", kind: .audiobook, title: "", startedAt: t0), generation: 1)
        let table: [(String, URL, Int?, VoiceMarginImport.Refusal)] = [
            ("empty file", try recording("empty.m4a", bytes: 0), 5_000, .unreadable),
            ("not audio", try recording("notes.txt"), nil, .unreadable),
            ("missing file", root.appending(path: "gone.m4a"), 5_000, .unreadable),
            ("over ten minutes", try recording("long.m4a"), VoiceMarginImport.maxDurationMs + 1, .tooLong),
        ]
        for (label, url, ms, expected) in table {
            do {
                _ = try await add(url, model: model, files: files, ms: ms)
                XCTFail("\(label) must be refused")
            } catch let error as AddMarginShortcutError {
                XCTAssertEqual(error, .voiceRefused(expected), label)
                XCTAssertEqual(error.localizedDescription, expected.line, label)
            }
        }
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins, [])
        XCTAssertEqual(keptRecordings(), [])
    }

    func testTheShortcutsOwnFileIsNeverRemoved() async throws {
        let model = makeModel()
        let files = LiveSessionFileWorker(root: root)
        let url = try recording()
        _ = try await add(url, model: model, files: files)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
