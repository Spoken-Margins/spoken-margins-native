import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #2708 PR 2, inside the app: a Margin taken with a photo, on real files in a temporary Application Support. The
/// picture is a generated fixture where the camera would return one (a simulator has no camera); the real camera is part
/// of the owner's phone check.
@MainActor
final class LiveSessionPhotoMarginAppTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var temp: URL!
    private var store: LiveSessionPhotoStore!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "live-photo-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "support")
        temp = base.appending(path: "tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        store = LiveSessionPhotoStore(root: root, temporaryRoot: temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// A 3,000 x 4,000 picture, bigger than a kept photo may be, so fitting it is part of the test.
    private func fixturePicture() throws -> Data {
        let size = CGSize(width: 3_000, height: 4_000)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.darkGray.setFill()
            for line in 0..<20 { context.fill(CGRect(x: 300, y: 400 + CGFloat(line) * 150, width: 2_400, height: 40)) }
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func staged() async throws -> LiveSessionPhotoStore.Staged {
        let picture = try fixturePicture()
        let staged = await LiveSessionPhotoIntake.stage(picture, in: store)
        return try XCTUnwrap(staged)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func openScreen(_ files: LiveSessionFileWorker) async throws -> LiveSessionController {
        try await files.save(
            LiveSession(id: "live-photo", kind: .paper, title: "Book", startedAt: Date().addingTimeInterval(-300)), generation: 1)
        let screen = LiveSessionController(sessionId: "live-photo", files: files)
        screen.load()
        try await waitUntil("the session to load") { screen.session?.id == "live-photo" }
        return screen
    }

    func testThePictureIsFittedToWhatAMarginMayKeep() async throws {
        let picture = try await staged()
        XCTAssertLessThanOrEqual(max(picture.widthPx, picture.heightPx), LiveSessionPhoto.maxLongEdgePixels)
        XCTAssertLessThanOrEqual(picture.byteCount, LiveSessionPhoto.maxByteCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: picture.url.path), "waiting in the temporary folder")
    }

    func testAWrittenMarginWithAPhotoHasItsFileInPlaceAndSurvivesAReload() async throws {
        let files = LiveSessionFileWorker(root: root)
        let screen = try await openScreen(files)
        let picture = try await staged()

        await screen.addMargin(text: "The paragraph about the budget", whereNote: "page 118", adjustmentMs: 0, markedAt: Date(), photo: picture)

        let margin = try XCTUnwrap(screen.session?.margins.first)
        let photo = try XCTUnwrap(margin.validPhoto)
        XCTAssertNil(screen.errorMessage)
        let kept = try XCTUnwrap(store.fileURL(for: photo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: picture.url.path), "moved out of the temporary folder")
        try await waitUntil("the Margin to be saved") { await files.session(id: "live-photo")?.margins.first?.photo == photo }
        screen.stopPolling()
    }

    func testDeletingTheMarginDeletesItsPhotoFile() async throws {
        let files = LiveSessionFileWorker(root: root)
        let screen = try await openScreen(files)
        let picture = try await staged()
        await screen.addMargin(text: "words", whereNote: nil, adjustmentMs: 0, markedAt: Date(), photo: picture)
        let margin = try XCTUnwrap(screen.session?.margins.first)
        let kept = try XCTUnwrap(store.fileURL(for: try XCTUnwrap(margin.validPhoto)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))

        screen.removeMargin(id: margin.id)

        try await waitUntil("the photo file to go") { !FileManager.default.fileExists(atPath: kept.path) }
        screen.stopPolling()
    }

    func testAPhotoThatCannotBeKeptSavesTheMarginAndSaysSo() async throws {
        let files = LiveSessionFileWorker(root: root)
        let screen = try await openScreen(files)
        let picture = try await staged()
        try FileManager.default.removeItem(at: picture.url) // the system cleared the temporary folder

        await screen.addMargin(text: "words that matter", whereNote: nil, adjustmentMs: 0, markedAt: Date(), photo: picture)

        let margin = try XCTUnwrap(screen.session?.margins.first, "the words are never lost to the picture")
        XCTAssertNil(margin.photo)
        XCTAssertEqual(screen.errorMessage, LiveSessionPhotoMargin.couldNotKeepLine)
        screen.stopPolling()
    }

    func testCancellingARecordingThrowsItsPhotoAwayButWritingInsteadKeepsIt() async throws {
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))

        let thrownAway = try await staged()
        capture.start(sessionId: "s1", photo: thrownAway)
        XCTAssertEqual(capture.photo, thrownAway)
        XCTAssertNil(capture.cancel(sessionId: "s1"))
        XCTAssertNil(capture.photo)
        try await waitUntil("Cancel to delete the picture with the recording") { !FileManager.default.fileExists(atPath: thrownAway.url.path) }

        let kept = try await staged()
        // Another session id, so the first recording's late start can't be mistaken for this one.
        capture.start(sessionId: "s2", photo: kept, placedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(capture.photoPlacedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(capture.cancel(sessionId: "s2", keepingPhoto: true), kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.url.path), "Write instead keeps the picture for the written Margin")
        XCTAssertNil(capture.photoPlacedAt)
    }

    func testAPhotoHandedToARecordingThatIsAlreadyGoingIsNotLeftBehind() async throws {
        let capture = LiveSessionSpokenCapture(files: LiveSessionFileWorker(root: root))
        capture.start(sessionId: "s")
        let late = try await staged()

        capture.start(sessionId: "s", photo: late)

        try await waitUntil("a photo with no recording to join to be deleted") { !FileManager.default.fileExists(atPath: late.url.path) }
        capture.cancel(sessionId: "s")
    }
}
