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
    @State private var loaded: Loaded = .loading

    private enum Loaded {
        case loading
        case picture(UIImage)
        case missing
    }

    var body: some View {
        content
            .frame(width: isSquare ? height : nil, height: height)
            .background(AppColors.watchControl)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            Image(systemName: "camera").foregroundStyle(AppColors.watchSecondary)
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
