import SessionKit
import SessionKitPersistence
import SwiftUI
import UIKit

/// Where a Timeline's table and figure pictures are read from, and which rows have one (#3895). Set once on the
/// Timeline screen from a single listing of the item's clip folder, so a row asks a set, not the disk, and nothing is
/// decoded until a row with a picture is drawn.
struct TimelineClipSource: Equatable {
    var store: PDFClipStore?
    var itemId: String
    var available: PDFClipStore.Available

    static let none = TimelineClipSource(store: nil, itemId: "", available: .none)

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store?.directory == rhs.store?.directory && lhs.itemId == rhs.itemId && lhs.available == rhs.available
    }

    func has(floatId: String?) -> Bool { available.contains(floatId: floatId) }

    /// What a picture is, apart from where it sits: the item, the file's name and the folder's version. Clip ids come
    /// from page and position (`float-p1-1`), so two PDFs share them; a picture, and anything that keeps one decoded,
    /// is keyed by all three, never by the float id alone.
    func pictureKey(forFloat floatId: String) -> String {
        "\(itemId)/\(available.stamp)/\(floatId)"
    }

    /// The picture decoded for a row, off the main thread.
    func rowImage(forFloat floatId: String) async -> UIImage? {
        await image(forFloat: floatId, maxPixelSize: 900)
    }

    /// The picture at the size it was saved, for the viewer.
    func fullImage(forFloat floatId: String) async -> UIImage? {
        await image(forFloat: floatId, maxPixelSize: Int(PDFClipGeometry.maximumClipPixels))
    }

    private func image(forFloat floatId: String, maxPixelSize: Int) async -> UIImage? {
        guard let store else { return nil }
        let itemId = itemId
        return await Task.detached(priority: .userInitiated) {
            store.data(forFloat: floatId, itemId: itemId).flatMap { SourcePicture.still($0, maxPixelSize: maxPixelSize) }
        }.value
    }
}

private struct TimelineClipSourceKey: EnvironmentKey {
    static let defaultValue = TimelineClipSource.none
}

extension EnvironmentValues {
    var timelineClips: TimelineClipSource {
        get { self[TimelineClipSourceKey.self] }
        set { self[TimelineClipSourceKey.self] = newValue }
    }
}

/// The picture a row draws: set only on a row whose float has a clip saved. It carries the source that said so, so
/// the picture is read from the same item the row was decided against, and the row redraws when the source changes.
struct TimelineRowClip: Equatable {
    let source: TimelineClipSource
    let floatId: String
    let spokenLabel: String

    var key: String { source.pictureKey(forFloat: floatId) }

    init?(entry: TimelineRailEntry, in clips: TimelineClipSource) {
        guard case .sourceText(let source) = entry.action, let floatId = source.floatId,
              clips.has(floatId: floatId), let spoken = source.clipSpokenLabel else { return nil }
        self.source = clips
        self.floatId = floatId
        spokenLabel = spoken
    }
}

/// The picture a viewer opens: which float of which item's folder, and the words every surface says for it. It holds
/// the source it was opened from, so the viewer shows the picture the listener tapped even if the Timeline moves to
/// another item behind it.
struct TimelineClipSelection: Identifiable, Equatable {
    let source: TimelineClipSource
    let floatId: String
    let title: String
    let spokenLabel: String
    var id: String { source.pictureKey(forFloat: floatId) }

    /// A card on the Now tab opens the same viewer, with the words `PDFClipLabel` gives it (#4588).
    init?(source: TimelineClipSource, floatId: String, title: String, spokenLabel: String) {
        guard source.has(floatId: floatId) else { return nil }
        self.source = source
        self.floatId = floatId
        self.title = title
        self.spokenLabel = spokenLabel
    }

    init?(entry: TimelineSourceContent.Entry, source: TimelineClipSource) {
        guard let floatId = entry.floatId, source.has(floatId: floatId) else { return nil }
        self.source = source
        self.floatId = floatId
        title = entry.label ?? TimelineClipPresentation.noun(for: entry.floatKind).capitalized
        spokenLabel = TimelineClipPresentation.spokenLabel(kind: entry.floatKind, label: entry.label, pageIndex: entry.pageIndex)
    }
}

extension TimelineSourceContent.Entry {
    /// What VoiceOver adds after a row's words when the row has a picture, so it is known before the action is chosen.
    var clipSpokenLabel: String? {
        floatId == nil ? nil : TimelineClipPresentation.spokenLabel(kind: floatKind, label: label, pageIndex: pageIndex)
    }
}

/// A table's or figure's picture in its Timeline row: under the row's label, above its text, scaled to fit and never
/// stretched (#3895). It reads the file when the row is drawn and shows nothing until then or if the file is gone, so
/// the row is its text exactly as it was before a picture existed. Tapping it opens the viewer; tapping the rest of the
/// row does what it always did.
struct TimelineClipPicture: View {
    let clip: TimelineRowClip
    let open: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: TimelineClipPresentation.rowMaximumHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppColors.border) }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: open)
                    .accessibilityHidden(true) // the row reads the picture's label; the action opens it
                    .accessibilityIdentifier("timeline.clip.\(clip.floatId)")
            }
        }
        .padding(.top, image == nil ? 0 : 4)
        // Keyed by item, folder version and float, so a row that now belongs to another item, or whose file was
        // replaced by a re-import, drops what it had and reads again; it never keeps another picture's pixels.
        .task(id: clip.key) {
            image = nil
            image = await clip.source.rowImage(forFloat: clip.floatId)
        }
    }
}

/// A table or figure at full screen: pinch to zoom, double-tap to zoom in and back, Done (#3895).
struct TimelineClipViewer: View {
    let selection: TimelineClipSelection
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImage(image: image, spokenLabel: selection.spokenLabel)
                        .ignoresSafeArea(edges: .bottom)
                } else if finished {
                    Label("This picture is no longer on this phone.", systemImage: "photo.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView().tint(.white).accessibilityLabel("Loading picture")
                }
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text("Done").minimumTapTarget() }
                        .accessibilityIdentifier("timeline.clip.done")
                }
            }
        }
        .task(id: selection.id) {
            image = await selection.source.fullImage(forFloat: selection.floatId)
            finished = true
        }
        .accessibilityIdentifier("timeline.clip.viewer")
    }
}

/// A UIScrollView that fits the picture to the screen and zooms it. `UIScrollView` is used because it already does
/// pinch, pan inside the zoomed picture and double-tap the way people expect; SwiftUI has none of them for an image.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let spokenLabel: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.imageView.image = image
        scrollView.imageView.contentMode = .scaleAspectFit
        scrollView.imageView.isAccessibilityElement = true
        scrollView.imageView.accessibilityTraits = .image
        scrollView.imageView.accessibilityLabel = spokenLabel
        scrollView.addSubview(scrollView.imageView)
        context.coordinator.scrollView = scrollView
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {
        if scrollView.imageView.image !== image {
            scrollView.imageView.image = image
            scrollView.zoomScale = 1
        }
        scrollView.imageView.accessibilityLabel = spokenLabel
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: ZoomScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let scale: CGFloat = 2.5
            let point = recognizer.location(in: scrollView.imageView)
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }
}

/// Keeps the picture fitted to the screen while it isn't zoomed (a rotation or a resize refits it).
private final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == 1, imageView.frame != bounds else { return }
        imageView.frame = bounds
        contentSize = bounds.size
    }
}
