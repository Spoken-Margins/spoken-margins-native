import Foundation
import XCTest
@testable import SessionKit

/// #4925: a screenshot or photo handed to Add Margin or Add Voice Margin is kept through the #2708 photo store when the
/// Margin goes into a live or quick session, and never otherwise. Real temporary directories; the picture's bytes are
/// stand-ins, because filing never looks inside a photo.
final class AddMarginPictureFilingTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var temp: URL!
    private var staging: LiveSessionPhotoStore!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let bytes = Data(repeating: 0xCD, count: 2_048)

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "add-margin-picture-\(UUID().uuidString)")
        root = base.appending(path: "support")
        temp = base.appending(path: "tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        staging = LiveSessionPhotoStore(root: root, temporaryRoot: temp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func stage() throws -> LiveSessionPhotoStore.Staged {
        try staging.stage(data: bytes, widthPx: 1_200, heightPx: 800)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func keptFile(_ margin: LiveSessionMargin) throws -> URL {
        let photo = try XCTUnwrap(margin.validPhoto, "the Margin names a photo within the rules")
        return try XCTUnwrap(LiveSessionPhotoStore(root: root).fileURL(for: photo))
    }

    /// Nothing is left in the temporary folder that no Margin owns.
    private func stagedLeftover() -> [String] {
        let folder = temp.appending(path: LiveSessionPhotoStore.stagingFolderName)
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func running(_ worker: LiveSessionFileWorker) async throws {
        try await worker.save(LiveSession(id: "live", kind: .paper, title: "Book", startedAt: t0), generation: 1)
    }

    // MARK: Written Margin, running live session

    func testAWrittenMarginInARunningSessionKeepsThePictureBesideIt() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await running(worker)
        let staged = try stage()

        let filing = await worker.addWrittenMargin(text: "  see this page ", markedAt: t0.addingTimeInterval(30), staged: staged)

        XCTAssertFalse(filing.photoFailed)
        let margin = try XCTUnwrap(filing.session?.margins.first)
        XCTAssertEqual(margin.text, "see this page")
        XCTAssertTrue(exists(try keptFile(margin)))
        XCTAssertFalse(exists(staged.url), "moved, not copied")
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins.first?.photo, margin.photo, "what was saved, not only what was returned")
    }

    func testAnEmptyTextSavesNothingAndLeavesNoStagedFile() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await running(worker)
        let filing = await worker.addWrittenMargin(text: " \n ", markedAt: t0, staged: try stage())
        XCTAssertNil(filing.session)
        XCTAssertEqual(stagedLeftover(), [])
        let stored = await worker.session(id: "live")
        XCTAssertEqual(stored?.margins, [])
    }

    func testNoRunningSessionSavesNothingAndLeavesNoStagedFile() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let filing = await worker.addWrittenMargin(text: "words", markedAt: t0, staged: try stage())
        XCTAssertNil(filing.session)
        XCTAssertEqual(stagedLeftover(), [])
    }

    func testAPictureThatCannotBeMovedStillSavesTheWordsAndSaysSo() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await running(worker)
        let staged = try stage()
        try FileManager.default.removeItem(at: staged.url) // the system cleared the temporary folder

        let filing = await worker.addWrittenMargin(text: "words survive", markedAt: t0.addingTimeInterval(5), staged: staged)

        XCTAssertTrue(filing.photoFailed)
        let margin = try XCTUnwrap(filing.session?.margins.first)
        XCTAssertEqual(margin.text, "words survive")
        XCTAssertNil(margin.photo)
    }

    func testTheWrittenWorkerWithoutAPictureIsUnchanged() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await running(worker)
        let filed = await worker.addWrittenMargin(text: "plain", markedAt: t0.addingTimeInterval(5))
        XCTAssertEqual(filed?.margins.map(\.text), ["plain"])
        XCTAssertNil(filed?.margins.first?.photo)
    }

    // MARK: Written Margin, quick session

    func testAWrittenMarginThatStartsAQuickSessionKeepsThePicture() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let staged = try stage()

        let filing = await worker.fileWrittenMarginAsQuick(text: "no session ran", markedAt: t0, now: t0, staged: staged)

        XCTAssertFalse(filing.photoFailed)
        let session = try XCTUnwrap(filing.session)
        XCTAssertEqual(session.isQuick, true)
        let margin = try XCTUnwrap(session.margins.first)
        let file = try keptFile(margin)
        XCTAssertTrue(exists(file))
        XCTAssertTrue(file.path.contains(LiveSessionPhotoStore.component(for: session.id)), "kept under the session the Margin landed in")
        XCTAssertEqual(stagedLeftover(), [])
    }

    func testASecondPictureJoinsTheSameQuickSessionAndKeepsBothPictures() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let first = await worker.fileWrittenMarginAsQuick(text: "one", markedAt: t0, now: t0, staged: try stage())
        let second = await worker.fileWrittenMarginAsQuick(
            text: "two", markedAt: t0.addingTimeInterval(20), now: t0.addingTimeInterval(20), staged: try stage())
        XCTAssertEqual(first.session?.id, second.session?.id)
        let margins = try XCTUnwrap(second.session?.margins)
        XCTAssertEqual(margins.count, 2)
        let files = try margins.map(keptFile)
        XCTAssertEqual(Set(files).count, 2)
        XCTAssertTrue(files.allSatisfy(exists))
    }

    func testAnEmptyQuickWrittenMarginSavesNothingAndLeavesNoStagedFile() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let filing = await worker.fileWrittenMarginAsQuick(text: "   ", markedAt: t0, now: t0, staged: try stage())
        XCTAssertNil(filing.session)
        XCTAssertEqual(stagedLeftover(), [])
        let all = await worker.allSessions()
        XCTAssertTrue(all.isEmpty)
    }

    func testAQuickMarginThatFallsInsideANamedSessionKeepsThePictureThere() async throws {
        let worker = LiveSessionFileWorker(root: root)
        var ended = LiveSession(id: "live", kind: .paper, title: "Book", startedAt: t0)
        ended.endedAt = t0.addingTimeInterval(600)
        try await worker.save(ended, generation: 1)
        // Inside the span of a session that has ended: filing puts it there, and the picture goes with it.
        let filing = await worker.fileWrittenMarginAsQuick(text: "during", markedAt: t0.addingTimeInterval(60), now: t0.addingTimeInterval(900), staged: try stage())
        let session = try XCTUnwrap(filing.session)
        let margin = try XCTUnwrap(session.margins.first { $0.text == "during" })
        XCTAssertFalse(filing.photoFailed, "never a picture reported lost while the Margin names a file")
        XCTAssertEqual(margin.photo != nil, !filing.photoFailed)
        if margin.photo != nil { XCTAssertTrue(exists(try keptFile(margin))) }
        XCTAssertEqual(stagedLeftover(), [])
    }

    func testAQuickMarginWhoseStagedFileIsGoneStillSavesTheWordsAndSaysSo() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let staged = try stage()
        try FileManager.default.removeItem(at: staged.url)
        let filing = await worker.fileWrittenMarginAsQuick(text: "words", markedAt: t0, now: t0, staged: staged)
        XCTAssertTrue(filing.photoFailed)
        XCTAssertEqual(filing.session?.margins.map(\.text), ["words"])
        XCTAssertNil(filing.session?.margins.first?.photo)
    }

    func testASpokenQuickMarginWhoseStagedFileIsGoneStillSavesTheMarginAndSaysSo() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let staged = try stage()
        try FileManager.default.removeItem(at: staged.url)
        let filing = await worker.fileSpokenMarginAsQuick(
            marginId: "phone-3", audioPath: "c.m4a", markedAt: t0, durationMs: 1_000, spokenOn: "phone", now: t0, staged: staged)
        XCTAssertTrue(filing.photoFailed)
        XCTAssertEqual(filing.session?.margins.first?.audioPath, "c.m4a")
        XCTAssertNil(filing.session?.margins.first?.photo)
    }

    // MARK: Spoken Margin

    func testASpokenMarginInAQuickSessionKeepsThePicture() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let filing = await worker.fileSpokenMarginAsQuick(
            marginId: "phone-1", audioPath: "SpokenMargins/interjections/a.m4a", markedAt: t0, durationMs: 4_000, spokenOn: "phone",
            now: t0, staged: try stage())
        XCTAssertFalse(filing.photoFailed)
        let margin = try XCTUnwrap(filing.session?.margins.first)
        XCTAssertEqual(margin.audioPath, "SpokenMargins/interjections/a.m4a")
        XCTAssertTrue(exists(try keptFile(margin)))
    }

    func testASpokenMarginAlreadyFiledTakesNoSecondPicture() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let first = await worker.fileSpokenMarginAsQuick(
            marginId: "phone-1", audioPath: "a.m4a", markedAt: t0, durationMs: 1_000, spokenOn: "phone", now: t0, staged: try stage())
        XCTAssertNotNil(first.session)
        let again = await worker.fileSpokenMarginAsQuick(
            marginId: "phone-1", audioPath: "a.m4a", markedAt: t0, durationMs: 1_000, spokenOn: "phone", now: t0, staged: try stage())
        XCTAssertNil(again.session)
        XCTAssertEqual(stagedLeftover(), [], "the second picture was removed, not left behind")
    }

    func testTheSpokenQuickWorkerWithoutAPictureIsUnchanged() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let filed = await worker.fileSpokenMarginAsQuick(
            marginId: "phone-2", audioPath: "b.m4a", markedAt: t0, durationMs: 1_000, spokenOn: "phone", now: t0)
        XCTAssertEqual(filed?.margins.first?.audioPath, "b.m4a")
        XCTAssertNil(filed?.margins.first?.photo)
    }

    // MARK: Nothing leaves the phone

    func testAKeptPictureLivesUnderTheOnPhonePhotoFolderOnly() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await running(worker)
        _ = await worker.addWrittenMargin(text: "private page", markedAt: t0.addingTimeInterval(5), staged: try stage())
        // The packet writer never reads this folder: `LiveSessionPhotoTests` fails if SessionKitSharing starts to use the
        // photo store. Here only where the file is.
        let stored = await worker.session(id: "live")
        let photo = try XCTUnwrap(stored?.margins.first?.validPhoto)
        XCTAssertTrue(photo.path.hasPrefix(LiveSessionPhoto.folder))
    }
}
