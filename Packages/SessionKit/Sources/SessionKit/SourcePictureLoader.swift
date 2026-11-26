#if canImport(ImageIO)
import CryptoKit
import Foundation
import ImageIO

/// The bytes of a picture an imported page shows, fetched when Timeline first draws its row and kept in Caches.
///
/// Rows show the page's own pictures, GIFs included, while the listener hears the article (owner, 2026-11-14 and
/// 2026-11-17: load when the row is drawn, not on a tap). The import never fetches them, so an article with pictures
/// costs nothing until its Timeline is opened. The request carries no cookies, so the picture's host learns no more
/// than an address and that someone opened it.
/// Unchecked Sendable: NSCache is thread-safe and every other stored property is immutable.
public final class SourcePictureLoader: @unchecked Sendable {
    /// A picture larger than this is left on the web: its row says so and opens the page.
    public static let maximumBytes = 16 * 1_024 * 1_024

    public static let shared = SourcePictureLoader(
        diskDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "SourcePictures", directoryHint: .isDirectory),
        fetch: { try await SourcePictureLoader.download($0, session: SourcePictureLoader.session) }
    )

    private let memory = NSCache<NSURL, NSData>()
    private let diskDirectory: URL?
    private let fetch: @Sendable (URL) async throws -> Data
    private let inFlight = InFlight()

    public init(diskDirectory: URL?, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.diskDirectory = diskDirectory
        self.fetch = fetch
        memory.totalCostLimit = 48 * 1_024 * 1_024
    }

    public func cachedData(for url: URL) -> Data? {
        memory.object(forKey: url as NSURL) as Data?
    }

    /// The picture's bytes from memory, then disk, then the network. Nil when it can't be fetched, is too large, or
    /// isn't a picture ImageIO can read, or decodes to more than `SourcePicture.maximumPixels`.
    public func data(for url: URL) async -> Data? {
        if let cached = cachedData(for: url) { return cached }
        let task = await inFlight.task(for: url) { [self] in await load(url) }
        return await task.value
    }

    private func load(_ url: URL) async -> Data? {
        let diskURL = diskFileURL(for: url)
        if let diskURL, let data = try? Data(contentsOf: diskURL), SourcePicture.isWithinDecodeBudget(data) {
            remember(data, for: url)
            return data
        }
        guard let data = try? await fetch(url), data.count <= Self.maximumBytes, SourcePicture.isWithinDecodeBudget(data) else {
            return nil
        }
        remember(data, for: url)
        if let diskURL {
            try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
        }
        return data
    }

    private func remember(_ data: Data, for url: URL) {
        memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
    }

    private func diskFileURL(for url: URL) -> URL? {
        guard let diskDirectory else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appending(path: name, directoryHint: .notDirectory)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil // the loader keeps its own copies
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// The picture's bytes from its host, never more than `maximumBytes` of them in memory. A body announced as larger
    /// is refused before it is read, and one with no length (or a wrong one) is cancelled as soon as it passes the
    /// cap, so a 400 MB GIF costs the listener neither the data nor the memory.
    public static func download(_ url: URL, session: URLSession, maximumBytes: Int = maximumBytes) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return data
    }

    /// One load per address at a time: a row and its detail sheet share it.
    private actor InFlight {
        private var tasks: [URL: Task<Data?, Never>] = [:]

        func task(for url: URL, _ work: @escaping @Sendable () async -> Data?) -> Task<Data?, Never> {
            if let task = tasks[url] { return task }
            let task = Task.detached(priority: .utility) { await work() }
            tasks[url] = task
            Task { [weak self] in
                _ = await task.value
                await self?.finish(url)
            }
            return task
        }

        private func finish(_ url: URL) { tasks[url] = nil }
    }
}

/// Reading a picture's bytes with ImageIO.
public enum SourcePicture {
    /// The picture's size in pixels, or nil when ImageIO can't read it.
    public static func size(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    public static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// A decoded still, handed from the thread that decoded it to the one that draws it. A CGImage is immutable.
    public struct DecodedStill: @unchecked Sendable {
        public let image: CGImage
    }

    /// The first frame, decoded no larger than `maxPixelSize` on its long side. The decode is the slow part of showing
    /// a picture, so a caller on the main actor uses `decodedStill` instead.
    public static func stillImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// `stillImage`, run on a background thread, so a very large picture never holds the main actor while it decodes
    /// (#4451). `decoder` is what runs there; a test passes one that records its thread and calls `stillImage`.
    public static func decodedStill(
        _ data: Data, maxPixelSize: Int,
        decoder: @escaping @Sendable (Data, Int) -> CGImage? = { SourcePicture.stillImage($0, maxPixelSize: $1) }
    ) async -> DecodedStill? {
        await Task.detached(priority: .userInitiated) {
            decoder(data, maxPixelSize).map { DecodedStill(image: $0) }
        }.value
    }

    /// The most pixels one frame of a picture may have. A frame decodes to about 4 bytes a pixel, so 16 million is about
    /// 64 MB. The 16 MB download cap limits a picture's bytes, not what it decodes to: a 100 KB single-colour GIF can
    /// be 10,000 by 10,000 pixels, 400 MB a frame.
    public static let maximumPixels = 16_000_000
    /// An animation decodes frame after frame at full size on the main queue, so it gets a quarter of that, about 16 MB
    /// a frame. A bigger animated picture shows its still.
    public static let maximumAnimatedPixels = 4_000_000

    /// The picture's pixels in one frame. Zero when ImageIO can't read it.
    public static func pixelCount(of data: Data) -> Int {
        guard let size = size(of: data) else { return 0 }
        return Int(size.width) * Int(size.height)
    }

    /// Whether ImageIO can read the picture and it is small enough to decode: no more than `maximumPixels` a frame.
    public static func isWithinDecodeBudget(_ data: Data) -> Bool {
        let pixels = pixelCount(of: data)
        return pixels > 0 && pixels <= maximumPixels
    }

    /// Whether the picture has several frames and is small enough to play them at full size.
    public static func canAnimate(_ data: Data) -> Bool {
        guard isAnimated(data) else { return false }
        let pixels = pixelCount(of: data)
        return pixels > 0 && pixels <= maximumAnimatedPixels
    }
}
#endif
