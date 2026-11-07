import XCTest
import SessionKit
import SessionKitAudio
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #2505: a tap on a Margin's moment reads the session, the Margin and the item off the main thread. The screen the
/// tap came from stays until they are read, and a late result is dropped when the listener left.
@MainActor
final class MarginMomentTapTests: XCTestCase {
    private var priorTermsVersion: Any?
    private var priorTermsDate: Any?
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        SpokenMarginsTerms.recordAcceptance()
        root = FileManager.default.temporaryDirectory.appending(path: "margin-moment-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        for (value, key) in [(priorTermsVersion, SpokenMarginsTerms.acceptanceVersionKey), (priorTermsDate, SpokenMarginsTerms.acceptanceDateKey)] {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try super.tearDownWithError()
    }

    private final class StubRecorder: RecordingClient {
        func beginRecording() throws {}
        func finishRecording(audioRef: String?) throws -> String { "" }
        func cancelRecording() throws {}
    }

    private func fixture(status: String = "active", openHome: Bool = true) throws -> (model: Gate1AppModel, row: MarginRow) {
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: StubRecorder(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveItem(Item(id: "tap-source", title: "Tap source", mediaType: "podcast", text: nil,
            externalReference: "local", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: root.appending(path: "source.m4a").absoluteString,
                durationMs: 180_000, nativeMediaId: "tap-source")))
        model.startItem(id: "tap-source")
        let margin = Interjection(
            id: "margin-\(UUID().uuidString)", itemId: "tap-source", sessionId: try XCTUnwrap(model.snapshot.sessionId),
            targetType: .item, targetId: "tap-source", createdAt: Date(timeIntervalSince1970: 1), roughPercent: 50,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 120_000),
            audioPath: root.appending(path: "margin.m4a").path, audioStatus: "recorded", transcriptionStatus: "transcribed",
            transcript: "A note.", cleanedTranscript: nil, displayText: nil, status: status)
        try store.saveInterjection(margin)
        try store.saveItem(Item(id: "other-source", title: "Other source", mediaType: "podcast", text: nil,
            externalReference: "local", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: root.appending(path: "other.m4a").absoluteString,
                durationMs: 180_000, nativeMediaId: "other-source")))
        model.refreshMarginRows()
        if openHome { model.openHome() }
        return (model, MarginRow(interjection: margin, itemTitle: "Tap source", sessionDate: nil))
    }

    func testTheTapKeepsTheScreenUntilTheReadsAreDoneThenPlaysTheMoment() async throws {
        let (model, row) = try fixture()
        defer { model.endMarginMoment(); model.pause() }
        MarginMomentTap.start(row, model: model)
        XCTAssertEqual(model.screen, .home, "nothing is read on the main thread, so nothing has changed yet")
        XCTAssertNil(model.marginMoment)
        await model.settleItemOpen()
        XCTAssertEqual(model.screen, .playback)
        XCTAssertNotNil(model.marginMoment)
        XCTAssertEqual(model.selectedItem.id, "tap-source")
    }

    func testLeavingTheScreenBeforeTheReadsAreDoneDropsTheMoment() async throws {
        let (model, row) = try fixture()
        defer { model.endMarginMoment(); model.pause() }
        MarginMomentTap.start(row, model: model)
        model.showSettingsTab()
        let after = model.screen
        XCTAssertNotEqual(after, .home, "the listener really went to another screen")
        await model.settleItemOpen()
        XCTAssertEqual(model.screen, after, "a late result must not cover the screen the listener chose")
        XCTAssertNil(model.marginMoment)
    }

    func testAMarginThatIsNoLongerActiveSaysSoAndPlaysNothing() async throws {
        let (model, row) = try fixture(status: "deleted")
        defer { model.endMarginMoment(); model.pause() }
        MarginMomentTap.start(row, model: model)
        await model.settleItemOpen()
        XCTAssertNil(model.marginMoment)
        XCTAssertEqual(model.screen, .home)
        XCTAssertNotNil(model.lastError)
    }

    func testAnotherItemStartedWhileTheReadsRunDropsTheMoment() async throws {
        let (model, row) = try fixture(openHome: false)
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertEqual(model.screen, .playback, "the tap comes from the playback screen, which a new item keeps")
        MarginMomentTap.start(row, model: model)
        model.startItem(id: "other-source") // starting an item does not touch the open gate
        XCTAssertEqual(model.screen, .playback)
        await model.settleItemOpen()
        XCTAssertNil(model.marginMoment, "a late result must not take over newer playback")
        XCTAssertEqual(model.snapshot.itemId, "other-source")
    }

    func testARecordingStartedWhileTheReadsRunDropsTheMoment() async throws {
        let (model, row) = try fixture(openHome: false)
        defer { model.endMarginMoment(); model.pause() }
        MarginMomentTap.start(row, model: model)
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.recordingNavigationIsLocked)
        await model.settleItemOpen()
        XCTAssertNil(model.marginMoment)
    }
}
