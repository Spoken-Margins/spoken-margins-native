#if canImport(ImageIO)
import CryptoKit
import Foundation
import ImageIO

/// The bytes of a picture an imported page shows, kept in Caches once fetched (#2032).
///
/// Rows show the page's own pictures, GIFs included, while the listener hears the article (owner, 2026-11-14). The
/// import never fetches them, and neither does drawing a Timeline row: #2032 allows no request beyond the page the
/// listener asked for, so a picture is fetched only when the listener taps it (`Fetching.network`). A row draws a
/// picture that is already stored (`Fetching.storedOnly`). The request carries no cookies, so the picture's host
/// learns no more than an address and that someone opened it.
/// Unchecked Sendable: NSCache is thread-safe and every other stored property is immutable.
public final class SourcePictureLoader: @unchecked Sendable {
    /// Whether a load may go to the network.
    public enum Fetching: Sendable {
        /// Memory and disk only. What a Timeline row asks for when it is drawn.
        case storedOnly
        /// Memory, then disk, then the picture's host. Only after the listener taps the picture.
        case network
    }

    /// A picture larger than this is left on the web: its row says so and opens the page.
    public static let maximumBytes = 16 * 1_024 * 1_024

    /// Posted on the main actor with the picture's URL as its object when a fetched picture is stored, so a row
    /// that drew a placeholder can draw it.
    public static let didStorePicture = Notification.Name("SourcePictureLoader.didStorePicture")

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

    /// The picture's bytes from memory, then disk, then (only with `.network`) its host. Nil when it isn't stored
    /// and may not be fetched, can't be fetched, is too large, or isn't a picture ImageIO can read.
    public func data(for url: URL, fetching: Fetching) async -> Data? {
        if let cached = cachedData(for: url) { return cached }
        switch fetching {
        case .storedOnly:
            return await Task.detached(priority: .utility) { [self] in loadStored(url) }.value
        case .network:
            let task = await inFlight.task(for: url) { [self] in await load(url) }
            return await task.value
        }
    }

    private func loadStored(_ url: URL) -> Data? {
        guard let diskURL = diskFileURL(for: url), let data = try? Data(contentsOf: diskURL),
              SourcePicture.size(of: data) != nil else { return nil }
        remember(data, for: url)
        return data
    }

    private func load(_ url: URL) async -> Data? {
        if let stored = loadStored(url) { return stored }
        guard let data = try? await fetch(url), data.count <= Self.maximumBytes, SourcePicture.size(of: data) != nil else {
            return nil
        }
        remember(data, for: url)
        if let diskURL = diskFileURL(for: url) {
            try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.didStorePicture, object: url) }
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
}
#endif
