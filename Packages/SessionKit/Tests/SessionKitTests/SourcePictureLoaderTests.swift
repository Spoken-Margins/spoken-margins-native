import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SessionKit

/// #2032: a Timeline row never fetches a picture by itself, and a download never holds more than the cap in memory.
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

    private actor FetchCount {
        private(set) var value = 0
        func add() { value += 1 }
    }

    // MARK: Drawing a row makes no request (audit finding 1 on a9dc647)

    func testARowDrawsOnlyAStoredPictureAndTheTapFetchesIt() async throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.example.com/p.png"))
        let picture = try png()
        let fetches = FetchCount()
        let loader = SourcePictureLoader(diskDirectory: folder) { _ in
            await fetches.add()
            return picture
        }

        let drawn = await loader.data(for: url, fetching: .storedOnly)
        XCTAssertNil(drawn, "nothing is stored yet, so the row has nothing to draw")
        let fetchesAfterDraw = await fetches.value
        XCTAssertEqual(fetchesAfterDraw, 0, "drawing a row must not ask the picture's host")

        let stored = expectation(forNotification: SourcePictureLoader.didStorePicture, object: url)
        let tapped = await loader.data(for: url, fetching: .network)
        XCTAssertEqual(tapped, picture)
        let fetchesAfterTap = await fetches.value
        XCTAssertEqual(fetchesAfterTap, 1)
        await fulfillment(of: [stored], timeout: 2)

        let laterFetches = FetchCount()
        let nextLaunch = SourcePictureLoader(diskDirectory: folder) { _ in
            await laterFetches.add()
            return Data()
        }
        let redrawn = await nextLaunch.data(for: url, fetching: .storedOnly)
        XCTAssertEqual(redrawn, picture, "a picture the listener loaded once is drawn from disk")
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
