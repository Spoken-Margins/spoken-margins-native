import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SessionKit

/// #2032: a Timeline row fetches its picture when it is drawn (owner, 2026-11-17), and a download never holds more
/// than the cap in memory.
/// Real URLSession over a stub protocol, real ImageIO and real files in a temporary folder.
final class SourcePictureLoaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "SourcePictureLoaderTests-\(UUID().uuidString)")
        EndlessPictureURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0.45, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0.45, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func solidPicture(type: String, width: Int, height: Int, frames: Int = 1) throws -> Data {
        let image = try solidImage(width: width, height: height)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private actor FetchCount {
        private(set) var value = 0
        func add() { value += 1 }
    }

    // MARK: Drawing a row fetches its picture, once

    func testDrawingARowFetchesThePictureAndALaterLaunchReadsItFromDisk() async throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/p.png"))
        let picture = try png()
        let fetches = FetchCount()
        let loader = SourcePictureLoader(diskDirectory: folder) { _ in
            await fetches.add()
            return picture
        }

        let drawn = await loader.data(for: url)
        XCTAssertEqual(drawn, picture, "drawing a row loads its picture")
        let fetchesAfterDraw = await fetches.value
        XCTAssertEqual(fetchesAfterDraw, 1)
        let drawnAgain = await loader.data(for: url)
        XCTAssertEqual(drawnAgain, picture)
        let fetchesAfterSecondDraw = await fetches.value
        XCTAssertEqual(fetchesAfterSecondDraw, 1, "the second draw comes from memory")

        let laterFetches = FetchCount()
        let nextLaunch = SourcePictureLoader(diskDirectory: folder) { _ in
            await laterFetches.add()
            return Data()
        }
        let redrawn = await nextLaunch.data(for: url)
        XCTAssertEqual(redrawn, picture, "a picture fetched once is drawn from disk on the next launch")
        let laterFetchCount = await laterFetches.value
        XCTAssertEqual(laterFetchCount, 0)
    }

    // MARK: The cap limits the download, not only the result (audit finding 2 on a9dc647)

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EndlessPictureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testAnUnsizedBodyIsStoppedOnceItPassesTheCap() async throws {
        let url = try XCTUnwrap(URL(string: "https://pictures.example/unsized.gif"))
        do {
            let data = try await SourcePictureLoader.download(url, session: session(), maximumBytes: 8 * 1_024)
            XCTFail("a body with no Content-Length that never ends was read whole: \(data.count) bytes")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
        let sent = EndlessPictureURLProtocol.waitUntilStopped()
        XCTAssertLessThan(sent, EndlessPictureURLProtocol.chunkLimit / 4, "the download was cancelled soon after the cap")
    }

    func testABodyAnnouncedOverTheCapIsRefusedBeforeItIsRead() async throws {
        let url = try XCTUnwrap(URL(string: "https://pictures.example/sized.gif"))
        do {
            let data = try await SourcePictureLoader.download(url, session: session(), maximumBytes: 8 * 1_024)
            XCTFail("a body announced as 10 MB was read: \(data.count) bytes")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
        let sent = EndlessPictureURLProtocol.waitUntilStopped()
        XCTAssertLessThan(sent, EndlessPictureURLProtocol.chunkLimit / 4)
    }

    func testAPictureUnderTheCapArrivesWhole() async throws {
        let url = try XCTUnwrap(URL(string: "https://pictures.example/small.png"))
        EndlessPictureURLProtocol.smallBody = try png()
        let data = try await SourcePictureLoader.download(url, session: session(), maximumBytes: 8 * 1_024)
        XCTAssertEqual(data, EndlessPictureURLProtocol.smallBody)
        XCTAssertNotNil(SourcePicture.size(of: data))
    }

    func testAFailedResponseIsNotAPicture() async throws {
        let url = try XCTUnwrap(URL(string: "https://pictures.example/missing.png"))
        do {
            _ = try await SourcePictureLoader.download(url, session: session())
            XCTFail("a 404 was kept")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    // MARK: A picture's pixels are capped as well as its bytes (#4411 audit)

    func testAPictureThatDecodesToTooManyPixelsIsNeverHandedToARow() async throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/huge.png"))
        let side = Int(Double(SourcePicture.maximumPixels).squareRoot()) + 8 // a little over the budget
        let huge = try solidPicture(type: "public.png", width: side, height: side)
        XCTAssertLessThan(huge.count, SourcePictureLoader.maximumBytes, "small in bytes, large in pixels")
        XCTAssertFalse(SourcePicture.isWithinDecodeBudget(huge))
        let loader = SourcePictureLoader(diskDirectory: folder) { _ in huge }
        let loaded = await loader.data(for: url)
        XCTAssertNil(loaded, "the row says the picture didn't load instead of decoding it")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(kept, [], "and nothing was kept on disk to decode later")
    }

    func testASmallPictureIsWithinTheBudgetAndAnUnreadableOneIsNot() throws {
        XCTAssertTrue(SourcePicture.isWithinDecodeBudget(try png()))
        XCTAssertFalse(SourcePicture.isWithinDecodeBudget(Data("not a picture".utf8)))
        XCTAssertEqual(SourcePicture.pixelCount(of: try png()), 12)
        XCTAssertEqual(SourcePicture.pixelCount(of: Data()), 0)
    }

    func testOnlyASmallAnimatedPictureIsPlayed() throws {
        let small = try solidPicture(type: "com.compuserve.gif", width: 8, height: 6, frames: 2)
        XCTAssertTrue(SourcePicture.isAnimated(small))
        XCTAssertTrue(SourcePicture.canAnimate(small))
        let side = Int(Double(SourcePicture.maximumAnimatedPixels).squareRoot()) + 8 // over the animation budget, under the still budget
        let large = try solidPicture(type: "com.compuserve.gif", width: side, height: side, frames: 2)
        XCTAssertTrue(SourcePicture.isAnimated(large))
        XCTAssertTrue(SourcePicture.isWithinDecodeBudget(large), "its still can be shown")
        XCTAssertFalse(SourcePicture.canAnimate(large), "its frames would each decode at full size")
        XCTAssertFalse(SourcePicture.canAnimate(try png()), "a still picture does not animate")
    }

    // MARK: A still decodes off the main thread (#4451)

    /// Records which thread a decode ran on.
    private final class DecodeThread: @unchecked Sendable {
        private let lock = NSLock()
        private var onMain: [Bool] = []
        func record() { lock.lock(); onMain.append(Thread.isMainThread); lock.unlock() }
        var ranOnMainThread: [Bool] { lock.lock(); defer { lock.unlock() }; return onMain }
    }

    /// A caller on the main actor (a Timeline row) must not decode there: ImageIO can decode a whole PNG or GIF before
    /// it scales it down, which holds the main thread for as long as that takes.
    @MainActor
    func testAStillIsDecodedOffTheMainThreadWhenAskedForFromTheMainActor() async throws {
        let side = Int(Double(SourcePicture.maximumPixels).squareRoot()) // the largest picture a row is handed
        let large = try solidPicture(type: "public.png", width: side, height: side)
        XCTAssertTrue(SourcePicture.isWithinDecodeBudget(large))
        let thread = DecodeThread()
        let decoded = await SourcePicture.decodedStill(large, maxPixelSize: 900) { data, size in
            thread.record()
            return SourcePicture.stillImage(data, maxPixelSize: size)
        }
        XCTAssertEqual(thread.ranOnMainThread, [false], "decoded once, and not on the main thread")
        let image = try XCTUnwrap(decoded?.image)
        XCTAssertEqual(max(image.width, image.height), 900, "scaled down to the size the row asked for")
    }

    /// While a still decodes the main actor is free: the decode here waits on a gate that only the main actor opens, so
    /// one that ran on the main actor would never see it opened (the wait gives up after 30 seconds and the test fails).
    @MainActor
    func testTheMainActorStaysFreeWhileAStillDecodes() async throws {
        let large = try solidPicture(type: "public.png", width: 3_000, height: 3_000)
        let gate = DispatchSemaphore(value: 0)
        let decoding = Task { @MainActor in
            await SourcePicture.decodedStill(large, maxPixelSize: 900) { data, size in
                guard gate.wait(timeout: .now() + 30) == .success else { return nil }
                return SourcePicture.stillImage(data, maxPixelSize: size)
            }
        }
        await Task.yield() // lets the decode start; the main actor is free to run this, then open the gate
        gate.signal()
        let decoded = await decoding.value
        XCTAssertNotNil(decoded, "the gate opened while the decode was waiting on it")
    }

    func testStillSizesNeighbouringInputs() async throws {
        let wide = try solidPicture(type: "public.png", width: 40, height: 10)
        let tall = try solidPicture(type: "public.png", width: 10, height: 40)
        let small = try png()
        let wideStill = try XCTUnwrap(SourcePicture.stillImage(wide, maxPixelSize: 20))
        XCTAssertEqual([wideStill.width, wideStill.height], [20, 5], "the long side is the cap")
        let tallStill = try XCTUnwrap(SourcePicture.stillImage(tall, maxPixelSize: 20))
        XCTAssertEqual([tallStill.width, tallStill.height], [5, 20])
        XCTAssertNotNil(SourcePicture.stillImage(small, maxPixelSize: 900), "a small picture decodes")
        let asyncSmall = await SourcePicture.decodedStill(small, maxPixelSize: 900)
        XCTAssertNotNil(asyncSmall)
        XCTAssertNil(SourcePicture.stillImage(Data("not a picture".utf8), maxPixelSize: 900))
        let asyncGarbage = await SourcePicture.decodedStill(Data("not a picture".utf8), maxPixelSize: 900)
        XCTAssertNil(asyncGarbage)
        XCTAssertNil(SourcePicture.stillImage(Data(), maxPixelSize: 900))
    }
}

/// Serves `/unsized.gif` as 1 KB chunks with no Content-Length, `/sized.gif` the same with a 10 MB Content-Length,
/// `/small.png` as `smallBody`, and anything else as a 404. It keeps sending until it is stopped or reaches
/// `chunkLimit`, so a client that reads everything gets 4 MB.
private final class EndlessPictureURLProtocol: URLProtocol, @unchecked Sendable {
    static let chunkLimit = 4_096
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chunksSent = 0
    nonisolated(unsafe) private static var finished = false
    nonisolated(unsafe) static var smallBody = Data()
    private let stopped = NSLock()
    nonisolated(unsafe) private var isStopped = false

    static func reset() { lock.lock(); chunksSent = 0; finished = false; smallBody = Data(); lock.unlock() }

    /// Chunks sent by the time the sender stopped, waiting up to five seconds for it to stop.
    static func waitUntilStopped() -> Int {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock()
            let done = finished
            lock.unlock()
            if done { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        lock.lock(); defer { lock.unlock() }
        return chunksSent
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pictures.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        var headers = ["Content-Type": path.hasSuffix(".png") ? "image/png" : "image/gif"]
        if path == "/sized.gif" { headers["Content-Length"] = "10000000" }
        if path == "/small.png" { headers["Content-Length"] = "\(Self.smallBody.count)" }
        let status = ["/unsized.gif", "/sized.gif", "/small.png"].contains(path) ? 200 : 404
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/small.png" {
            client?.urlProtocol(self, didLoad: Self.smallBody)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard status == 200 else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let sender = Sender(urlProtocol: self)
        DispatchQueue.global().async { sender.run() }
    }

    override func stopLoading() {
        stopped.lock(); isStopped = true; stopped.unlock()
    }

    private var wasStopped: Bool {
        stopped.lock(); defer { stopped.unlock() }
        return isStopped
    }

    /// Carries the protocol to the sending queue; URLProtocol is not Sendable, and only this queue sends afterwards.
    private struct Sender: @unchecked Sendable {
        let urlProtocol: EndlessPictureURLProtocol
        func run() { urlProtocol.sendChunks() }
    }

    fileprivate func sendChunks() {
        let chunk = Data(repeating: 0x47, count: 1_024)
        for _ in 0..<Self.chunkLimit {
            if wasStopped { break }
            client?.urlProtocol(self, didLoad: chunk)
            Self.lock.lock(); Self.chunksSent += 1; Self.lock.unlock()
            Thread.sleep(forTimeInterval: 0.000_5)
        }
        if !wasStopped { client?.urlProtocolDidFinishLoading(self) }
        Self.lock.lock(); Self.finished = true; Self.lock.unlock()
    }
}
