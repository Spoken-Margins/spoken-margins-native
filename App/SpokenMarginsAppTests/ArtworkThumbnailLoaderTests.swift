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

    // MARK: - A cell whose url changes (#2137)

    private func pngData(_ color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(image.pngData())
    }

    /// Holds a fetch until the test lets it go.
    private actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func open() {
            isOpen = true
            waiting?.resume()
            waiting = nil
        }
    }

    @MainActor
    func testACellThatMovesToAnotherArtworkDropsTheOldPictureAtOnce() async throws {
        let first = URL(string: "https://example.com/a.png")!
        let second = URL(string: "https://example.com/b.png")!
        let red = try pngData(.red)
        let gate = Gate()
        let loader = ArtworkThumbnailLoader(diskDirectory: nil) { url in
            if url == first { return red }
            await gate.wait()
            throw URLError(.badServerResponse)
        }
        let state = ArtworkThumbnailState(url: first, loader: loader)

        await state.show(first, loader: loader)
        XCTAssertNotNil(state.image(for: first))
        XCTAssertNil(state.image(for: second), "the frame drawn with the new url before the load starts shows no old picture")

        let next = Task { await state.show(second, loader: loader) }
        await Task.yield() // the second load is now held in its fetch
        XCTAssertNil(state.image, "the old picture is gone while the new one is still loading")
        await gate.open()
        await next.value
        XCTAssertNil(state.image(for: second), "the new row shows its placeholder when its artwork cannot load")
        await state.show(nil, loader: loader)
        XCTAssertNil(state.image)
    }

    @MainActor
    func testALoadStartedForAnEarlierUrlNeverLandsOnALaterOne() async throws {
        let slow = URL(string: "https://example.com/slow.png")!
        let quick = URL(string: "https://example.com/quick.png")!
        let slowData = try pngData(.red)
        let gate = Gate()
        let loader = ArtworkThumbnailLoader(diskDirectory: nil) { url in
            if url == slow {
                await gate.wait()
                return slowData
            }
            throw URLError(.badServerResponse)
        }
        let state = ArtworkThumbnailState(url: slow, loader: loader)

        let earlier = Task { await state.show(slow, loader: loader) }
        await Task.yield()
        earlier.cancel() // the cell moved on, as `.task(id:)` cancels the old task
        await state.show(quick, loader: loader)
        await gate.open()
        await earlier.value

        XCTAssertNil(state.image, "the slow load finished late and must not replace the newer url's state")
    }
}
