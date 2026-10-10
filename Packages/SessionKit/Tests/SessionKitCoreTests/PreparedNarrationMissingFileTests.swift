import XCTest
@testable import SessionKit

/// Whether an article's rendered narration file is gone from disk (#976). The Library and the audio
/// preparation pass ask this to decide between playing the file and preparing the article again. These
/// tests use real files, not a fake file system.
final class PreparedNarrationMissingFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("missing-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func existingFile() throws -> URL {
        let url = folder.appendingPathComponent("narration.caf")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func missingFile() -> URL {
        folder.appendingPathComponent("evicted.caf")
    }

    func testGeneratedNarrationIsMissingOnlyWhenItsFileIsGone() throws {
        let present = ItemMedia(sourceType: .generatedTTSPrerendered, url: try existingFile().absoluteString)
        let gone = ItemMedia(sourceType: .generatedTTSPrerendered, url: missingFile().absoluteString)

        XCTAssertFalse(PreparedNarrationFallback.isMissing(present))
        XCTAssertTrue(PreparedNarrationFallback.isMissing(gone))
    }

    func testTheFileIsFoundThroughTheNativeMediaIdWhenTheUrlIsAbsentBlankOrWhitespace() throws {
        let present = try existingFile().absoluteString
        let gone = missingFile().absoluteString
        let shapes: [(url: String?, nativeMediaId: String?, isMissing: Bool)] = [
            (nil, present, false), (nil, gone, true),
            ("", present, false), ("", gone, true),
            ("  \n", present, false), ("  \n", gone, true),
            (present, gone, false), (gone, present, true),
            ("  \(gone) ", nil, true)
        ]
        for shape in shapes {
            let media = ItemMedia(sourceType: .generatedTTSPrerendered, url: shape.url, nativeMediaId: shape.nativeMediaId)
            XCTAssertEqual(PreparedNarrationFallback.isMissing(media), shape.isMissing, "\(shape)")
        }
    }

    func testNarrationThatIsNotAFileCannotBeCalledMissing() {
        for url in [nil, "", "   ", "https://example.com/narration.caf", "not a url", "relative/narration.caf"] as [String?] {
            let media = ItemMedia(sourceType: .generatedTTSPrerendered, url: url)
            XCTAssertFalse(PreparedNarrationFallback.isMissing(media), "\(String(describing: url))")
        }
    }

    func testOnlyGeneratedNarrationCanBeMissing() {
        let gone = missingFile().absoluteString
        let others: [AudioSourceType] = [.nativeMediaFile, .remoteStream, .browserOwnedMedia, .generatedTTSRealtime]
        for source in others {
            XCTAssertFalse(PreparedNarrationFallback.isMissing(ItemMedia(sourceType: source, url: gone)), "\(source)")
        }
        XCTAssertFalse(PreparedNarrationFallback.isMissing(nil))
    }
}
