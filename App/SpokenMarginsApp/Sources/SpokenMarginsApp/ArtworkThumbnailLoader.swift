import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// #246: podcast artwork for small list cells. The drawer loaded artwork with a bare
/// `AsyncImage`: nothing was cached, so a row scrolled back into view downloaded again, and each
/// 1400–3000 px image was decoded at full size on the way to a 56 pt square. This loader
/// downsamples with ImageIO, off the main thread, to at most `maxPixelSize`, and keeps the small
/// image in memory and on disk (in Caches, which iOS may clear; it only holds copies).
/// Unchecked Sendable: NSCache is thread-safe and every other stored property is immutable.
final class ArtworkThumbnailLoader: @unchecked Sendable {
    /// 3× a 56 pt cell.
    static let maxPixelSize = 168

    static let shared = ArtworkThumbnailLoader(
        diskDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "ArtworkThumbnails", directoryHint: .isDirectory),
        fetch: { try await ArtworkThumbnailLoader.download($0) }
    )

    private let memory = NSCache<NSURL, UIImage>()
    private let diskDirectory: URL?
    private let fetch: @Sendable (URL) async throws -> Data
    private let inFlight = InFlight()

    init(diskDirectory: URL?, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.diskDirectory = diskDirectory
        self.fetch = fetch
        memory.countLimit = 300
    }

    /// The thumbnail if it's already in memory, so a row scrolled back into view shows its
    /// artwork on its first frame.
    func cachedThumbnail(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The thumbnail from memory, then disk, then the network. Nil when the image can't be
    /// fetched or decoded; the cell keeps its placeholder.
    func thumbnail(for url: URL) async -> UIImage? {
        if let cached = cachedThumbnail(for: url) { return cached }
        let task = await inFlight.task(for: url) { [self] in
            await load(url)
        }
        return await task.value
    }

    private func load(_ url: URL) async -> UIImage? {
        if let cached = cachedThumbnail(for: url) { return cached }
        let diskURL = diskFileURL(for: url)
        if let diskURL, let data = try? Data(contentsOf: diskURL), let image = Self.downsample(data) {
            memory.setObject(image, forKey: url as NSURL)
            return image
        }
        guard let data = try? await fetch(url), let image = Self.downsample(data) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        if let diskURL, let small = image.jpegData(compressionQuality: 0.85) {
            try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? small.write(to: diskURL, options: .atomic)
        }
        return image
    }

    private func diskFileURL(for url: URL) -> URL? {
        guard let diskDirectory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appending(path: "\(name).jpg", directoryHint: .notDirectory)
    }

    /// Decodes straight to a thumbnail no larger than `maxPixelSize` on its long side, without
    /// decoding the full-size image first.
    static func downsample(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil // the loader keeps its own small copies
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private static func download(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await session.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// One load per URL at a time: rows that ask for the same artwork share it.
    private actor InFlight {
        private var tasks: [URL: Task<UIImage?, Never>] = [:]

        func task(for url: URL, _ work: @escaping @Sendable () async -> UIImage?) -> Task<UIImage?, Never> {
            if let task = tasks[url] { return task }
            let task = Task.detached(priority: .utility) { await work() }
            tasks[url] = task
            Task { [weak self] in
                _ = await task.value
                await self?.finish(url)
            }
            return task
        }

        private func finish(_ url: URL) {
            tasks[url] = nil
        }
    }
}

/// What one artwork cell shows. A cell is reused for another row, or its row's artwork changes, so `url` changes
/// under it. The picture must follow the url: the old one goes the moment the url changes, and a load that was
/// started for an earlier url never lands on a later one (#2137).
@MainActor
final class ArtworkThumbnailState: ObservableObject {
    @Published private(set) var image: UIImage?
    /// The url `image` belongs to.
    private var imageURL: URL?

    init(url: URL?, loader: ArtworkThumbnailLoader) {
        image = url.flatMap(loader.cachedThumbnail(for:))
        imageURL = image == nil ? nil : url
    }

    /// The picture for `url`, or nil when the one held is for another url. The view asks with its current url, so the
    /// one frame drawn with the new url before `show` runs cannot show the old picture.
    func image(for url: URL?) -> UIImage? { imageURL == url ? image : nil }

    /// Shows `url`: what is cached at once (nothing when it isn't, so the placeholder shows, not the previous
    /// picture), then the loaded image. A cancelled call, which means the cell moved to another url, leaves the
    /// image to the call that replaced it.
    func show(_ url: URL?, loader: ArtworkThumbnailLoader) async {
        image = url.flatMap(loader.cachedThumbnail(for:))
        imageURL = image == nil ? nil : url
        guard let url else { return }
        let loaded = await loader.thumbnail(for: url)
        guard !Task.isCancelled else { return }
        image = loaded
        imageURL = loaded == nil ? nil : url
    }
}

/// A small artwork square for list rows, loaded through `ArtworkThumbnailLoader`.
struct ArtworkThumbnail: View {
    let url: URL?
    private let loader: ArtworkThumbnailLoader
    /// Shown while the image loads or when it can't; nil keeps the headphones tile.
    private let fallback: AnyView?
    @StateObject private var state: ArtworkThumbnailState

    init(url: URL?, loader: ArtworkThumbnailLoader = .shared, fallback: AnyView? = nil) {
        self.url = url
        self.loader = loader
        self.fallback = fallback
        _state = StateObject(wrappedValue: ArtworkThumbnailState(url: url, loader: loader))
    }

    var body: some View {
        Group {
            if let image = state.image(for: url) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let fallback {
                fallback
            } else {
                AppColors.panel.overlay { Image(systemName: "headphones").foregroundStyle(AppColors.secondaryText) }
            }
        }
        .task(id: url) { await state.show(url, loader: loader) }
    }
}
