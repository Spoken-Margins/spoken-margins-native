import SessionKit
import SwiftUI
import UIKit

/// A photo's picture, small: the 48 pt square beside a row's words, or the thumbnail above the recorder. A picture that
/// can't be read shows a camera glyph instead, never a blank.
struct LiveSessionPhotoThumbnail: View {
    let source: LiveSessionPhotoSource
    var height: CGFloat = 48
    /// Square crops for a list row; the recorder shows the whole picture inside its height.
    var isSquare = true
    var maxPixelSize = 144
    var accessibilityText: String?
    /// The dark listening surface (the live session, Now Playing) or a light page (the item screen, Timeline, Margins
    /// tab, #4180). The page has no dark tile: it is clear while loading, and a missing file shows the page's secondary
    /// glyph inside its border outline, colour pairs the page already uses.
    var surface: Surface = .listening
    @State private var loaded: Loaded = .loading

    enum Surface {
        case listening
        case page
    }

    private enum Loaded {
        case loading
        case picture(UIImage)
        case missing
    }

    var body: some View {
        content
            .frame(width: isSquare ? height : nil, height: height)
            .background(surface == .page ? Color.clear : AppColors.watchControl)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if case .missing = loaded, surface == .page {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(AppColors.border, lineWidth: 1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText ?? "")
            .accessibilityHidden(accessibilityText == nil)
            .task(id: source) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loaded {
        case .picture(let image):
            if isSquare {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(uiImage: image).resizable().scaledToFit()
            }
        case .missing:
            Image(systemName: "camera")
                .foregroundStyle(surface == .page ? AppColors.secondaryText : AppColors.watchSecondary)
        case .loading:
            Color.clear
        }
    }

    private func load() async {
        guard let url = source.url else {
            loaded = .missing
            return
        }
        if let image = await LiveSessionPhotoImages.image(at: url, maxPixelSize: maxPixelSize) {
            loaded = .picture(image)
        } else {
            loaded = .missing
        }
    }
}
