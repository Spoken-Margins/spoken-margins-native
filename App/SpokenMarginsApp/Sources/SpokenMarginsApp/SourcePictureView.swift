import Foundation
import ImageIO
import SessionKit
import SwiftUI
import UIKit

extension SourcePicture {
    /// The first frame, decoded no larger than `maxPixelSize` on its long side. Slow for a large picture: call it off
    /// the main thread (`SourcePicture.decodedStill`).
    static func still(_ data: Data, maxPixelSize: Int) -> UIImage? {
        stillImage(data, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
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
    /// Bumped for each still asked for; the decode that comes back for an older one is dropped.
    private var stillGeneration = 0
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
        loadStill()
        startIfVisible()
    }

    /// Decodes the still off the main thread and draws it when it is done. A newer picture, or an animation that has
    /// started drawing its own frames, makes a late still a no-op.
    private func loadStill(clearing: Bool = true) {
        guard let data else { return }
        // A different picture clears the old one; Reduce Motion keeps the frame on screen until its still is ready.
        if clearing { imageView.image = nil }
        stillGeneration += 1
        let wanted = stillGeneration
        let maxPixelSize = maxPixelSize
        Task { [weak self] in
            let decoded = await SourcePicture.decodedStill(data, maxPixelSize: maxPixelSize)
            guard let self, self.stillGeneration == wanted, !self.isAnimating else { return }
            self.imageView.image = decoded.map { UIImage(cgImage: $0.image) }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { startIfVisible() }
    }

    @objc private func reduceMotionChanged() {
        if UIAccessibility.isReduceMotionEnabled {
            stop()
            loadStill(clearing: false)
        } else {
            startIfVisible()
        }
    }

    private func startIfVisible() {
        guard window != nil, !isAnimating, !UIAccessibility.isReduceMotionEnabled,
              let data, SourcePicture.canAnimate(data) else { return }
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
