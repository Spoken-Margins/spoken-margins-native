import SessionKit
import SwiftUI
import UIKit

/// What the Now tab's cards read from and how big they may be (#4588): the item's clip folder, as the Timeline reads it,
/// the width of the scene list and the height of the text area they sit in.
struct NowClipCards: Equatable {
    var source: TimelineClipSource
    var anchors: [PDFClipAnchor]
    var listWidth: Double
    var visibleHeight: Double

    static let none = NowClipCards(source: .none, anchors: [], listWidth: 0, visibleHeight: 0)

    /// The anchor of the card with this id (`-(index + 1)`), if there is one.
    func anchor(forCard id: Int) -> PDFClipAnchor? {
        let index = -id - 1
        return anchors.indices.contains(index) ? anchors[index] : nil
    }

    /// A card's height, with the space under it, as following's hold estimate counts it.
    func rowHeight(for anchor: PDFClipAnchor) -> Double {
        PlaybackLivePassage.ClipCardLayout.height(
            width: PlaybackLivePassage.ClipCardLayout.width(listWidth: listWidth),
            aspect: anchor.aspect, visibleHeight: visibleHeight)
            + PlaybackLivePassage.ClipHold.rowSpacing
    }
}

/// Pictures decoded for cards, kept for a few at a time so a card that scrolls back into view draws at once instead of
/// reading its file again (#4588). Keyed by item, folder version and float, as `TimelineClipSource.pictureKey` says, so a
/// picture is never shown for another item's float of the same id.
@MainActor
enum NowClipImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        return cache
    }()

    static func image(forKey key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    static func store(_ image: UIImage, forKey key: String) { cache.setObject(image, forKey: key as NSString) }
}

#if DEBUG
/// Which cards have had a body run, in order, so an app-hosted test can show where cards are drawn and that a long scene
/// draws only the cards near the screen (#4588). Counts each float once, however often its row redraws.
@MainActor
enum NowClipCardCounter {
    private(set) static var bodies = 0
    private(set) static var floatIds: [String] = []
    static func count(floatId: String) {
        bodies += 1
        if !floatIds.contains(floatId) { floatIds.append(floatId) }
    }
    static func reset() { floatIds = []; bodies = 0 }
}
#endif

/// A table's or figure's picture in the Now tab's scene, where it sits in the text (#4588). Its frame is sized from the
/// picture's aspect, so nothing jumps when the picture arrives. The picture is read only when the card is drawn, and it
/// never moves or pauses audio: a tap opens the viewer and nothing else changes.
struct NowClipCard: View {
    let anchor: PDFClipAnchor
    let cards: NowClipCards
    let open: (TimelineClipSelection) -> Void
    @State private var phase: Phase = .loading

    private enum Phase { case loading, shown(UIImage), failed }

    private var key: String { cards.source.pictureKey(forFloat: anchor.floatId) }

    private var height: Double {
        PlaybackLivePassage.ClipCardLayout.height(
            width: PlaybackLivePassage.ClipCardLayout.width(listWidth: cards.listWidth),
            aspect: anchor.aspect, visibleHeight: cards.visibleHeight)
    }

    var body: some View {
        #if DEBUG
        let _ = NowClipCardCounter.count(floatId: anchor.floatId)
        #endif
        Button(action: openViewer) {
            // The frame comes first and the picture is laid over it, fitted and centred: a card narrower than its
            // frame shows the card's own white, which reads as the page's margin.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay { content }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppColors.border, lineWidth: 0.5) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isShown)
        .padding(.leading, PlaybackLivePassage.ClipCardLayout.leadingInset)
        // A page stays white in Dark Mode: inverting it would change a figure's colours.
        .accessibilityIgnoresInvertColors(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PDFClipLabel.accessibilityLabel(anchor))
        .accessibilityValue(isFailed ? "Couldn't show this picture" : "")
        .accessibilityHint(PDFClipLabel.hint(for: anchor.kind))
        .accessibilityAddTraits(isFailed ? .isImage : [.isImage, .isButton])
        .accessibilityIdentifier("playback.now.clip.\(anchor.floatId)")
        // Keyed by item, folder version and float, so a card that now belongs to another item, or whose file was
        // replaced by a re-import, drops what it had and reads again. The decode is off the main actor and is
        // cancelled when the card leaves the screen.
        .task(id: key) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            Color.clear
        case .shown(let image):
            Image(uiImage: image).resizable().scaledToFit()
        case .failed:
            Text("Couldn't show this picture")
                .font(.footnote)
                // The card is paper and stays white in both appearances, so its words are a fixed dark grey, not a system colour that follows the theme.
                .foregroundStyle(Color(.darkGray))
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }

    private var isShown: Bool { if case .shown = phase { true } else { false } }
    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func load() async {
        let key = key
        if let cached = NowClipImageCache.image(forKey: key) {
            phase = .shown(cached)
            return
        }
        phase = .loading
        guard let image = await cards.source.rowImage(forFloat: anchor.floatId) else {
            // A cancelled task (the card scrolled away) is not a failed picture.
            if !Task.isCancelled { phase = .failed }
            return
        }
        NowClipImageCache.store(image, forKey: key)
        if !Task.isCancelled { phase = .shown(image) }
    }

    private func openViewer() {
        guard let selection = TimelineClipSelection(
            source: cards.source, floatId: anchor.floatId, title: anchor.numberLabel,
            spokenLabel: PDFClipLabel.accessibilityLabel(anchor)) else { return }
        open(selection)
    }
}
