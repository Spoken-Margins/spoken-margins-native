import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4180: a live-session photo shows beside its Margin on the saved item. The lookup (`SavedMarginPhotos`) is
/// host-tested in SessionKit; these check the app's wiring: the save updates the shared index before it returns (so the
/// item screen opened next draws its photos at once), a purge drops the entry at once and still removes the photo
/// folder, and a fresh index answers nil until it loads.
@MainActor
final class SavedMarginPhotoAppTests: XCTestCase {
    private var savedItemIds: [String] = []
    private var sessionIds: [String] = []

    override func tearDown() async throws {
        if let directory = Gate1AppModel.liveSessionDirectory {
            for itemId in savedItemIds {
                SavedMarginPhotoIndex.shared.remove(itemId: itemId)
                LiveSessionRecord.remove(itemId: itemId, from: directory)
            }
            for sessionId in sessionIds { LiveSessionPhotoStore(root: directory).removeFolder(sessionId: sessionId) }
        }
        savedItemIds = []
        sessionIds = []
        try await super.tearDown()
    }

    func testASavedSessionsPhotoIsInTheLookupAsSoonAsTheSaveReturns() async throws {
        let directory = try XCTUnwrap(Gate1AppModel.liveSessionDirectory)
        let model = makeModel()
        let (session, photoMarginId, plainMarginId) = try makePhotoSession(in: directory)

        let saved = try await model.saveLiveSession(session, transcript: nil, placed: [], recordingURL: nil)
        savedItemIds.append(saved.itemId)

        let links = try XCTUnwrap(LiveSessionRecord.load(itemId: saved.itemId, from: directory)?.savedMarginIds)
        let photoSavedId = try XCTUnwrap(links[photoMarginId])
        let plainSavedId = try XCTUnwrap(links[plainMarginId])
        XCTAssertEqual(SavedMarginPhotoIndex.shared.photo(forMarginId: photoSavedId)?.photo, session.margins[0].photo,
                       "the item screen opened after the save would draw no photo until a relaunch")
        XCTAssertNil(SavedMarginPhotoIndex.shared.photo(forMarginId: plainSavedId))
        XCTAssertNil(SavedMarginPhotoIndex.shared.photo(forMarginId: photoMarginId), "the live id is not the key")
    }

    func testPurgingTheItemDropsItsPhotoAtOnceAndRemovesItsFolder() async throws {
        let directory = try XCTUnwrap(Gate1AppModel.liveSessionDirectory)
        let model = makeModel()
        let (session, photoMarginId, _) = try makePhotoSession(in: directory)
        let saved = try await model.saveLiveSession(session, transcript: nil, placed: [], recordingURL: nil)
        savedItemIds.append(saved.itemId)
        let photoSavedId = try XCTUnwrap(LiveSessionRecord.load(itemId: saved.itemId, from: directory)?.savedMarginIds?[photoMarginId])
        XCTAssertNotNil(SavedMarginPhotoIndex.shared.photo(forMarginId: photoSavedId))
        let file = try XCTUnwrap(LiveSessionPhotoStore(root: directory).fileURL(for: XCTUnwrap(session.margins[0].photo)))

        model.removeLiveSessionRecord(itemId: saved.itemId)

        XCTAssertNil(SavedMarginPhotoIndex.shared.photo(forMarginId: photoSavedId), "a purged item still showed its photo")
        try await pollUntil { !FileManager.default.fileExists(atPath: file.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the purge left the session's photo behind")
    }

    func testAFreshIndexHasNothingUntilItLoads() {
        let index = SavedMarginPhotoIndex()
        XCTAssertNil(index.photo(forMarginId: "any-margin"))
        XCTAssertFalse(index.isLoaded)
    }

    // MARK: - Fixtures

    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        return model
    }

    /// An ended Paper book session with two written Margins, the first with a kept photo whose file exists (any bytes:
    /// the lookup never decodes it). Returns the session and the two live Margin ids.
    private func makePhotoSession(in directory: URL) throws -> (LiveSession, String, String) {
        let start = Date(timeIntervalSinceNow: -600)
        let sessionId = "live-4180-\(UUID().uuidString)"
        let photoMarginId = "m1-\(UUID().uuidString)"
        let plainMarginId = "m2-\(UUID().uuidString)"
        sessionIds.append(sessionId)
        var withPhoto = LiveSessionMargin(
            id: photoMarginId, text: "Figure on page 12", markedAt: start.addingTimeInterval(60), sessionOffsetMs: 60_000
        )
        let photo = try XCTUnwrap(LiveSessionPhoto(
            path: LiveSessionPhotoStore.relativePath(sessionId: sessionId, marginId: photoMarginId),
            widthPx: 64, heightPx: 64, byteCount: 4_096
        ))
        withPhoto.photo = photo
        let file = try XCTUnwrap(LiveSessionPhotoStore(root: directory).fileURL(for: photo))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 4_096).write(to: file)
        let session = LiveSession(
            id: sessionId, kind: .paper, title: "Reading group", startedAt: start, endedAt: Date(),
            margins: [
                withPhoto,
                LiveSessionMargin(id: plainMarginId, text: "Ask about chapter two", markedAt: start.addingTimeInterval(120), sessionOffsetMs: 120_000),
            ]
        )
        return (session, photoMarginId, plainMarginId)
    }
}
