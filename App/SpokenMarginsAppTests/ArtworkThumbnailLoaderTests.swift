import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #246 (found on the phone): the podcast drawer stuttered while scrolling. Its artwork came
/// through a bare AsyncImage: no cache, and every 1400–3000 px image decoded at full size for a
/// 56 pt square. The loader downsamples off the main thread and caches the small image.
final class ArtworkThumbnailLoaderTests: XCTestCase {
    private final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var readsOnMain = 0

        var count: Int { lock.withLock { reads } }
        var countOnMain: Int { lock.withLock { readsOnMain } }

        func record() {
            let onMain = Thread.isMainThread
            lock.withLock {
                reads += 1
                if onMain { readsOnMain += 1 }
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "artwork-thumbnails-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A real 3000 × 3000 px JPEG, the size podcast artwork often is.
    private func writeLargeJPEG(in directory: URL) throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 3000, height: 3000)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1500, height: 3000))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let url = directory.appending(path: "artwork.jpg")
        try data.write(to: url)
        return url
    }

    private func makeLoader(diskDirectory: URL?, log: ReadLog) -> ArtworkThumbnailLoader {
        ArtworkThumbnailLoader(diskDirectory: diskDirectory) { url in
            log.record()
            return try Data(contentsOf: url)
        }
    }

    func testDownsamplesA3000PixelJPEGAndServesTheSecondRequestWithoutReadingAgain() async throws {
        let directory = try temporaryDirectory()
        let source = try writeLargeJPEG(in: directory)
        let thumbnails = directory.appending(path: "thumbnails", directoryHint: .isDirectory)
        let log = ReadLog()
        let loader = makeLoader(diskDirectory: thumbnails, log: log)

        let loaded = await loader.thumbnail(for: source)
        let image = try XCTUnwrap(loaded?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), ArtworkThumbnailLoader.maxPixelSize, "downsampled to at most 3× a 56 pt cell")
        XCTAssertGreaterThan(min(image.width, image.height), 0)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.countOnMain, 0, "loaded off the main thread")

        let second = await loader.thumbnail(for: source)
        XCTAssertNotNil(second)
        XCTAssertEqual(log.count, 1, "the second request is served from memory")
        XCTAssertNotNil(loader.cachedThumbnail(for: source), "a row scrolled back into view shows it on its first frame")

        let relaunched = makeLoader(diskDirectory: thumbnails, log: log)
        let reloaded = await relaunched.thumbnail(for: source)
        let fromDisk = try XCTUnwrap(reloaded?.cgImage)
        XCTAssertLessThanOrEqual(max(fromDisk.width, fromDisk.height), ArtworkThumbnailLoader.maxPixelSize)
        XCTAssertEqual(log.count, 1, "after a relaunch the small copy on disk is used, not the original")
    }

    func testRowsAskingForTheSameArtworkAtOnceShareOneLoad() async throws {
        let directory = try temporaryDirectory()
        let source = try writeLargeJPEG(in: directory)
        let log = ReadLog()
        let loader = makeLoader(diskDirectory: nil, log: log)

        async let first = loader.thumbnail(for: source)
        async let second = loader.thumbnail(for: source)
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(log.count, 1)
    }

    func testDataThatIsNotAnImageKeepsThePlaceholder() async throws {
        let directory = try temporaryDirectory()
        let notAnImage = directory.appending(path: "artwork.jpg")
        try Data("<html>not found</html>".utf8).write(to: notAnImage)
        let loader = makeLoader(diskDirectory: directory.appending(path: "thumbnails"), log: ReadLog())
        let image = await loader.thumbnail(for: notAnImage)
        XCTAssertNil(image)
    }
}
