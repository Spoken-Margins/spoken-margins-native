import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #3880: Siri's Margin goes into a running live session before the item in the player.
@MainActor
final class AddMarginSiriRouteAppTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "siri-route-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    private func runningWorker(kind: ElsewhereKind = .audiobook, title: String = "") async throws -> LiveSessionFileWorker {
        let files = LiveSessionFileWorker(root: root)
        try await files.save(LiveSession(id: "live", kind: kind, title: title, startedAt: t0), generation: 1)
        return files
    }

    func testARunningLiveSessionTakesTheMarginAndSiriNamesIt() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        let name = try await AddMarginShortcutAction.perform(
            text: " test one ", toItemId: nil, in: model, files: files, now: t0.addingTimeInterval(30)
        )
        XCTAssertEqual(name, "your audiobook session")
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.text), ["test one"])
    }

    func testTheLiveSessionBeatsAnItemLoadedInThePlayer() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.hasActiveSession)
        model.refreshMarginRows()
        let before = model.marginRows.count
        let files = try await runningWorker(title: "Night read")
        let name = try await AddMarginShortcutAction.perform(text: "test two", toItemId: nil, in: model, files: files, now: t0.addingTimeInterval(30))
        XCTAssertEqual(name, "Night read")
        model.refreshMarginRows()
        XCTAssertEqual(model.marginRows.count, before)
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.text), ["test two"])
    }

    func testTheLiveSessionTakesItEvenWhileAPlayerMarginIsBeingWritten() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        model.beginWrittenMargin()
        let files = try await runningWorker()
        _ = try await AddMarginShortcutAction.perform(text: "both kept", toItemId: nil, in: model, files: files, now: t0.addingTimeInterval(30))
        XCTAssertNotNil(model.writtenMarginDraft)
        model.cancelWrittenMargin()
    }

    func testWithNoLiveSessionThePlayerStillTakesIt() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let files = LiveSessionFileWorker(root: root)
        let name = try await AddMarginShortcutAction.perform(text: "on the item", toItemId: nil, in: model, files: files)
        XCTAssertFalse(name.isEmpty)
        XCTAssertNotEqual(name, "your audiobook session")
        model.refreshMarginRows()
        XCTAssertTrue(model.marginRows.contains { $0.fullText == "on the item" })
    }

    func testNothingRunningRefusesWithTheNewWords() async throws {
        let model = makeModel()
        let files = LiveSessionFileWorker(root: root)
        do {
            _ = try await AddMarginShortcutAction.perform(text: "nowhere", toItemId: nil, in: model, files: files)
            XCTFail("Nothing is running, so it must refuse.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error, .nothingRunning)
            XCTAssertEqual(
                error.localizedDescription,
                "Nothing is running in Spoken Margins. Start a live session or play something, then ask again."
            )
        }
    }

    func testEmptyTextSavesNothingInTheLiveSession() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        do {
            _ = try await AddMarginShortcutAction.perform(text: " \n ", toItemId: nil, in: model, files: files)
            XCTFail("An empty Margin must be refused.")
        } catch let error as AddMarginShortcutError {
            XCTAssertEqual(error.localizedDescription, "The Margin was empty, so nothing was saved.")
        }
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins, [])
    }
}
