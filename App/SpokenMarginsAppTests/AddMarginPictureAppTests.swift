import AppIntents
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4925: Add Margin and Add Voice Margin take an optional screenshot or photo. It is kept with the Margin, on this phone,
/// when the Margin goes into a live or quick session; for a Library item the Margin is saved without it and the
/// confirmation line says so. An unreadable file never costs the words. Real files, real storage, the real model; the
/// fixture picture is drawn here, never from a real Library.
@MainActor
final class AddMarginPictureAppTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "add-margin-picture-app-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    private func runningWorker() async throws -> LiveSessionFileWorker {
        let files = LiveSessionFileWorker(root: root)
        try await files.save(LiveSession(id: "live", kind: .paper, title: "Night read", startedAt: t0), generation: 1)
        return files
    }

    /// A screenshot-sized picture, larger than a Margin may keep so the fitting step has work to do.
    private func fixtureImage(width: CGFloat = 3_000, height: CGFloat = 1_800) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill()
            context.fill(CGRect(x: 100, y: 100, width: width / 2, height: 80))
        }
        return image.pngData() ?? Data()
    }

    private func keptFile(_ margin: LiveSessionMargin) throws -> URL {
        let photo = try XCTUnwrap(margin.validPhoto, "the Margin names a photo within the rules")
        return try XCTUnwrap(LiveSessionPhotoStore(root: root).fileURL(for: photo))
    }

    private func recording() throws -> URL {
        let url = root.appending(path: "memo.m4a")
        try Data(repeating: 9, count: 64).write(to: url)
        return url
    }

    private func addVoice(
        _ picture: ShortcutPicture?, item: String? = nil, model: Gate1AppModel, files: LiveSessionFileWorker
    ) async throws -> ShortcutMarginFiled {
        try await AddVoiceMarginAction.perform(
            audio: try recording(), toItemId: item, picture: picture, in: model, files: files, supportDirectory: support,
            inspect: { _ in VoiceMarginImport.Inspection(durationMs: 5_000, isMPEG4Audio: true) }, now: t0
        )
    }

    // MARK: Add Margin

    func testAWrittenMarginInALiveSessionKeepsTheScreenshotDownscaled() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        let filed = try await AddMarginShortcutAction.perform(
            text: "see this page", toItemId: nil, picture: ShortcutPicture(data: fixtureImage()), in: model, files: files,
            now: t0.addingTimeInterval(30)
        )
        XCTAssertEqual(filed.name, "Night read")
        XCTAssertEqual(filed.picture, .kept)
        XCTAssertTrue(filed.dialogLine.hasSuffix("The picture is kept with it on this phone."))
        let stored = await files.session(id: "live")
        let margin = try XCTUnwrap(stored?.margins.first)
        let photo = try XCTUnwrap(margin.validPhoto)
        XCTAssertLessThanOrEqual(max(photo.widthPx, photo.heightPx), LiveSessionPhoto.maxLongEdgePixels)
        XCTAssertLessThanOrEqual(photo.byteCount, LiveSessionPhoto.maxByteCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try keptFile(margin).path))
    }

    func testAWrittenMarginWithNothingRunningKeepsTheScreenshotInAQuickSession() async throws {
        let model = makeModel()
        let files = LiveSessionFileWorker(root: root)
        let filed = try await AddMarginShortcutAction.perform(
            text: "from the book", toItemId: nil, picture: ShortcutPicture(data: fixtureImage()), in: model, files: files, now: t0
        )
        XCTAssertEqual(filed.name, SiriMarginRoute.quickSessionName)
        XCTAssertEqual(filed.picture, .kept)
        let sessions = await files.allSessions()
        let margin = try XCTUnwrap(sessions.first?.margins.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try keptFile(margin).path))
    }

    func testAMarginOnTheItemInThePlayerIsSavedWithoutThePictureAndSaysSo() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let files = LiveSessionFileWorker(root: root)
        let filed = try await AddMarginShortcutAction.perform(
            text: "on the episode", toItemId: nil, picture: ShortcutPicture(data: fixtureImage()), in: model, files: files, now: t0
        )
        XCTAssertEqual(filed.picture, .notKeptOnItem)
        XCTAssertTrue(filed.dialogLine.contains("not kept"), filed.dialogLine)
        model.refreshMarginRows()
        XCTAssertTrue(model.marginRows.contains { $0.fullText == "on the episode" }, "the Margin is saved")
        let sessions = await files.allSessions()
        XCTAssertTrue(sessions.isEmpty, "the picture did not start a session to hold it")
    }

    /// A chosen item comes first, even over a running live session (`SiriMarginRoute`): no picture is kept then.
    func testAChosenItemBeatsARunningSessionAndTheMarginIsSavedWithoutThePicture() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let files = try await runningWorker()
        let filed = try await AddMarginShortcutAction.perform(
            text: "on the chosen one", toItemId: "item-pill", picture: ShortcutPicture(data: fixtureImage()), in: model, files: files,
            now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(filed.picture, .notKeptOnItem)
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins, [], "the running session got neither the Margin nor the picture")
    }

    func testAFileThatIsGoneIsUnreadableAndTheMarginIsStillSaved() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        let filed = try await AddMarginShortcutAction.perform(
            text: "file vanished", toItemId: nil, picture: ShortcutPicture(fileURL: root.appending(path: "missing.png")), in: model,
            files: files, now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(filed.picture, .unreadable)
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.text), ["file vanished"])
    }

    func testAnUnreadableFileSavesTheMarginAndSaysThePictureWasNotKept() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        let filed = try await AddMarginShortcutAction.perform(
            text: "words stay", toItemId: nil, picture: ShortcutPicture(data: Data("not a picture".utf8)), in: model, files: files,
            now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(filed.picture, .unreadable)
        XCTAssertTrue(filed.dialogLine.contains("could not be read"), filed.dialogLine)
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins.map(\.text), ["words stay"])
        XCTAssertNil(stored?.margins.first?.photo)
    }

    func testAPictureOverTheInputCapIsRefusedLikeAnUnreadableOne() async throws {
        let big = ShortcutPicture(data: Data(count: ShortcutPicture.maxInputBytes + 1))
        let bytes = await big.bytes()
        XCTAssertNil(bytes)
    }

    func testAFileTheShortcutHoldsByAddressIsReadInPlaceAndLeftAlone() async throws {
        let url = root.appending(path: "screenshot.png")
        try fixtureImage().write(to: url)
        let model = makeModel()
        let files = try await runningWorker()
        let filed = try await AddMarginShortcutAction.perform(
            text: "by address", toItemId: nil, picture: ShortcutPicture(fileURL: url), in: model, files: files, now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(filed.picture, .kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the Shortcut's own file is never touched")
    }

    func testWithoutAPictureTheAnswerIsTheOldLine() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        let filed = try await AddMarginShortcutAction.perform(
            text: "plain", toItemId: nil, picture: nil, in: model, files: files, now: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(filed.picture, .noneGiven)
        XCTAssertEqual(filed.dialogLine, "Margin added to Night read.")
    }

    /// Siri asks only for what is required. Add Margin stays one question, so the picture must be optional.
    func testAddMarginsOnlyRequiredParameterIsItsText() {
        let intent = AddMarginToSpokenMarginsIntent()
        let parameters = Mirror(reflecting: intent).children.compactMap { child -> (name: String, optional: Bool)? in
            guard let label = child.label, label.hasPrefix("_") else { return nil }
            return (label, String(describing: type(of: child.value)).contains("Optional"))
        }
        XCTAssertEqual(Set(parameters.map(\.name)), ["_text", "_item", "_picture"])
        XCTAssertEqual(parameters.filter { !$0.optional }.map(\.name), ["_text"])
    }

    func testAddVoiceMarginsPictureIsOptionalToo() {
        let intent = AddVoiceMarginToSpokenMarginsIntent()
        let required = Mirror(reflecting: intent).children.compactMap { child -> String? in
            guard let label = child.label, label.hasPrefix("_") else { return nil }
            return String(describing: type(of: child.value)).contains("Optional") ? nil : label
        }
        XCTAssertEqual(required, ["_audio"])
    }

    // MARK: Add Voice Margin

    func testASpokenMarginInALiveSessionKeepsThePicture() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        let filed = try await addVoice(ShortcutPicture(data: fixtureImage()), model: model, files: files)
        XCTAssertEqual(filed.name, "Night read")
        XCTAssertEqual(filed.picture, .kept)
        let stored = await files.session(id: "live")
        let margin = try XCTUnwrap(stored?.margins.first)
        XCTAssertTrue(margin.isSpoken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try keptFile(margin).path))
    }

    func testASpokenMarginWithNothingRunningKeepsThePictureInAQuickSession() async throws {
        let model = makeModel()
        let files = LiveSessionFileWorker(root: root)
        let filed = try await addVoice(ShortcutPicture(data: fixtureImage()), model: model, files: files)
        XCTAssertEqual(filed.picture, .kept)
        let sessions = await files.allSessions()
        let margin = try XCTUnwrap(sessions.first?.margins.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try keptFile(margin).path))
    }

    func testASpokenMarginOnTheItemInThePlayerIsSavedWithoutThePictureAndSaysSo() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let files = LiveSessionFileWorker(root: root)
        let filed = try await addVoice(ShortcutPicture(data: fixtureImage()), model: model, files: files)
        XCTAssertEqual(filed.picture, .notKeptOnItem)
        let sessions = await files.allSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testAChosenItemBeatsARunningSessionForASpokenMarginToo() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let files = try await runningWorker()
        let filed = try await addVoice(ShortcutPicture(data: fixtureImage()), item: "item-pill", model: model, files: files)
        XCTAssertEqual(filed.picture, .notKeptOnItem)
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins, [])
    }

    func testAnUnreadablePictureNeverStopsASpokenMargin() async throws {
        let model = makeModel()
        let files = try await runningWorker()
        let filed = try await addVoice(ShortcutPicture(data: Data("nope".utf8)), model: model, files: files)
        XCTAssertEqual(filed.picture, .unreadable)
        let stored = await files.session(id: "live")
        XCTAssertEqual(stored?.margins.count, 1)
        XCTAssertNil(stored?.margins.first?.photo)
    }
}
