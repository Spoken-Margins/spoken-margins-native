import CryptoKit
import Foundation
import ImageIO
import SessionKit
import SwiftUI
import UIKit

/// The bytes of a picture an imported page shows, fetched when Timeline first draws its row and kept in Caches.
///
/// Rows show the page's own pictures, GIFs included, while the listener hears the article (owner, 2026-11-14). The
/// import never fetches them, so an article with pictures costs nothing until its Timeline is opened. The request
/// carries no cookies, so the picture's host learns no more than an address and that someone opened it.
/// Unchecked Sendable: NSCache is thread-safe and every other stored property is immutable.
final class SourcePictureLoader: @unchecked Sendable {
    /// A picture larger than this is left on the web: its row says so and opens the page.
    static let maximumBytes = 16 * 1_024 * 1_024

    static let shared = SourcePictureLoader(
        diskDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "SourcePictures", directoryHint: .isDirectory),
        fetch: { try await SourcePictureLoader.download($0) }
    )

    private let memory = NSCache<NSURL, NSData>()
    private let diskDirectory: URL?
    private let fetch: @Sendable (URL) async throws -> Data
    private let inFlight = InFlight()

    init(diskDirectory: URL?, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.diskDirectory = diskDirectory
        self.fetch = fetch
        memory.totalCostLimit = 48 * 1_024 * 1_024
    }

    func cachedData(for url: URL) -> Data? {
        memory.object(forKey: url as NSURL) as Data?
    }

    /// The picture's bytes from memory, then disk, then the network. Nil when it can't be fetched, is too large, or
    /// isn't a picture ImageIO can read.
    func data(for url: URL) async -> Data? {
        if let cached = cachedData(for: url) { return cached }
        let task = await inFlight.task(for: url) { [self] in await load(url) }
        return await task.value
    }

    private func load(_ url: URL) async -> Data? {
        let diskURL = diskFileURL(for: url)
        if let diskURL, let data = try? Data(contentsOf: diskURL), SourcePicture.size(of: data) != nil {
            remember(data, for: url)
            return data
        }
        guard let data = try? await fetch(url), data.count <= Self.maximumBytes, SourcePicture.size(of: data) != nil else {
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

    private static func download(_ url: URL) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            if http.expectedContentLength > Int64(maximumBytes) { throw URLError(.dataLengthExceedsMaximum) }
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
enum SourcePicture {
    /// The picture's size in pixels, or nil when ImageIO can't read it.
    static func size(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// The first frame, decoded no larger than `maxPixelSize` on its long side.
    static func still(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }
}

extension SourceElement {
    /// The picture a Timeline row draws: a picture's own address, or a YouTube video's still. Nil for anything else.
    var previewImageURL: URL? {
        switch kind {
        case .picture:
            return URL(string: url)
        case .embed:
            guard let id = Self.youTubeID(url) else { return nil }
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        case .link, .table:
            return nil
        }
    }

    static func youTubeID(_ address: String) -> String? {
        guard let components = URLComponents(string: address), var host = components.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") || host.hasPrefix("m.") { host = String(host.drop { $0 != "." }.dropFirst()) }
        let id: String?
        switch host {
        case "youtu.be":
            id = components.path.split(separator: "/").first.map(String.init)
        case "youtube.com", "youtube-nocookie.com":
            let parts = components.path.split(separator: "/").map(String.init)
            if parts.first == "watch" {
                id = components.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) {
                id = parts[1]
            } else {
                id = nil
            }
        default:
            id = nil
        }
        guard let id, id.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }
}

/// A page's picture, drawn at its own shape: a still, or a GIF or animated PNG that plays while it's on screen.
struct SourcePictureView: View {
    let url: URL
    /// What VoiceOver reads for the picture.
    let accessibilityText: String
    var maxPixelSize = 1_200
    private let loader = SourcePictureLoader.shared

    private enum Phase: Equatable { case loading, loaded(Data, CGSize), failed }
    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loaded(let data, let size):
                AnimatedPictureRepresentable(data: data, maxPixelSize: maxPixelSize)
                    .aspectRatio(size.width / size.height, contentMode: .fit)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityAddTraits(.isImage)
            case .loading:
                placeholder { ProgressView() }
                    .accessibilityLabel("Loading picture")
            case .failed:
                placeholder {
                    Label("Picture didn't load", systemImage: "photo.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) {
            if let data = loader.cachedData(for: url), let size = SourcePicture.size(of: data) {
                phase = .loaded(data, size)
                return
            }
            phase = .loading
            let data = await loader.data(for: url)
            guard !Task.isCancelled else { return }
            if let data, let size = SourcePicture.size(of: data) { phase = .loaded(data, size) } else { phase = .failed }
        }
    }

    private func placeholder(@ViewBuilder _ content: () -> some View) -> some View {
        AppColors.panel
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(content())
    }
}

/// Plays an animated picture one frame at a time with ImageIO, so a 700-frame GIF never sits decoded in memory, and
/// only while the view is in a window. With Reduce Motion on it shows the first frame.
private struct AnimatedPictureRepresentable: UIViewRepresentable {
    let data: Data
    let maxPixelSize: Int

    func makeUIView(context: Context) -> AnimatedPictureView {
        let view = AnimatedPictureView()
        view.show(data, maxPixelSize: maxPixelSize)
        return view
    }

    func updateUIView(_ view: AnimatedPictureView, context: Context) {
        view.show(data, maxPixelSize: maxPixelSize)
    }
}

final class AnimatedPictureView: UIView {
    private let imageView = UIImageView()
    private var data: Data?
    private var maxPixelSize = 1_200
    /// Bumped to stop the animation that is running: its next frame sees a newer generation and stops.
    private var generation = 0
    private var isAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isAccessibilityElement = false
        addSubview(imageView)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric) }

    func show(_ data: Data, maxPixelSize: Int) {
        guard data != self.data else { return }
        self.data = data
        self.maxPixelSize = maxPixelSize
        stop()
        imageView.image = SourcePicture.still(data, maxPixelSize: maxPixelSize)
        startIfVisible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { startIfVisible() }
    }

    @objc private func reduceMotionChanged() {
        if UIAccessibility.isReduceMotionEnabled {
            stop()
            if let data { imageView.image = SourcePicture.still(data, maxPixelSize: maxPixelSize) }
        } else {
            startIfVisible()
        }
    }

    private func startIfVisible() {
        guard window != nil, !isAnimating, !UIAccessibility.isReduceMotionEnabled,
              let data, SourcePicture.isAnimated(data) else { return }
        isAnimating = true
        generation += 1
        let running = generation
        // The block runs on the main queue, one decoded frame at a time.
        let status = CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self] _, image, stop in
            guard let self, self.generation == running else {
                stop.pointee = true
                return
            }
            self.imageView.image = UIImage(cgImage: image)
        }
        if status != noErr { isAnimating = false }
    }

    private func stop() {
        generation += 1
        isAnimating = false
    }
}

/// A page's table as a grid: header row bold, cells scrolling sideways when the table is wider than the screen.
struct SourceTableView: View {
    let rows: [[String]]
    /// How many body rows to draw; the rest are counted in a line under the grid. Nil draws them all.
    var bodyRowLimit: Int? = nil

    var body: some View {
        let header = rows.first ?? []
        let body = Array(rows.dropFirst())
        let shown = bodyRowLimit.map { Array(body.prefix($0)) } ?? body
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.subheadline.weight(.semibold))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(.subheadline).frame(maxWidth: 220, alignment: .leading)
                            }
                        }
                    }
                }
                .foregroundStyle(AppColors.text)
                .textSelection(.enabled)
            }
            if shown.count < body.count {
                Text(body.count - shown.count == 1 ? "1 more row" : "\(body.count - shown.count) more rows")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
