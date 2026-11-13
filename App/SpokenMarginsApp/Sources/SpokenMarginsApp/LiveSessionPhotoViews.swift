import QuickLook
import SessionKit
import SwiftUI
import UIKit

/// Loads the pictures of a live session's photo Margins for the screen (#2708). The read and the scaling run off the
/// main actor (ImageIO's thumbnail call decodes only what the size needs); only the finished small picture comes
/// back to be drawn, and it is kept in memory so a list that scrolls doesn't read the file again.
@MainActor
enum LiveSessionPhotoImages {
    private static let cache = NSCache<NSString, UIImage>()

    /// The picture at `url` scaled to `maxPixelSize` on its longest side. Nil when the file can't be read: a photo that
    /// is gone is its own state, and the screen says so.
    static func image(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let data = await Task.detached(priority: .utility) {
            LiveSessionPhotoEncoder.thumbnail(of: url, maxPixelSize: maxPixelSize, quality: 0.8)
        }.value
        guard let data, let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Where a kept photo's file is (a path join; nothing is read). Nil when the reference breaks the rules.
    nonisolated static func fileURL(for photo: LiveSessionPhoto) -> URL? {
        LiveSessionFileWorker.shared.root.flatMap { LiveSessionPhotoStore(root: $0).fileURL(for: photo) }
    }

    /// Forgets a picture whose file was removed, so a later Margin never shows a stale one.
    static func forget(_ photo: LiveSessionPhoto) {
        guard let url = fileURL(for: photo) else { return }
        for size in [144, 1_600] { cache.removeObject(forKey: "\(url.path)#\(size)" as NSString) }
    }
}

/// Where a photo's picture comes from: a photo just taken and waiting for its words, or one a Margin keeps.
enum LiveSessionPhotoSource: Equatable {
    case waiting(URL)
    case kept(LiveSessionPhoto)

    var url: URL? {
        switch self {
        case .waiting(let url): url
        case .kept(let photo): LiveSessionPhotoImages.fileURL(for: photo)
        }
    }
}

/// The photo above a Margin's words on the Margin screen: full width, at most 40% of the screen tall, with the Margin's
/// text alternative as its label. Tapping opens it in Quick Look (pinch to zoom, Done, VoiceOver come with it). A file
/// that is gone shows the text alternative and says so.
struct LiveSessionPhotoDetail: View {
    let photo: LiveSessionPhoto
    let altText: String
    /// 40% of the screen the Margin is on, which the caller measures.
    let maxHeight: CGFloat
    @State private var loaded: Loaded = .loading
    @State private var previewURL: URL?

    private enum Loaded {
        case loading
        case picture(UIImage)
        case missing
    }

    var body: some View {
        content
            .quickLookPreview($previewURL)
            .task(id: photo) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loaded {
        case .picture(let image):
            Button {
                previewURL = LiveSessionPhotoImages.fileURL(for: photo)
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(altText)
            .accessibilityHint("Opens the photo full screen")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("marginDetail.photo")
        case .missing:
            VStack(alignment: .leading, spacing: 4) {
                Label(altText, systemImage: "camera").font(.subheadline)
                Text(LiveSessionPhotoMargin.missingFileLine)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("marginDetail.photo.missing")
        case .loading:
            Color.clear.frame(height: 1)
        }
    }

    private func load() async {
        guard let url = LiveSessionPhotoImages.fileURL(for: photo),
              let image = await LiveSessionPhotoImages.image(at: url, maxPixelSize: 1_600)
        else {
            loaded = .missing
            return
        }
        loaded = .picture(image)
    }
}

/// What the recording screen and the writing sheet show above the Margin's words after a photo was taken: the picture,
/// about 120 pt tall, and one line that helps the listener say something useful.
struct LiveSessionPhotoLead: View {
    let url: URL
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LiveSessionPhotoThumbnail(
                source: .waiting(url), height: 120, isSquare: false, maxPixelSize: 480,
                accessibilityText: LiveSessionPhotoMargin.thumbnailAccessibilityLabel)
                .accessibilityIdentifier("liveSession.photo.thumbnail")
            if let hint {
                Text(hint)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("liveSession.photo.hint")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
