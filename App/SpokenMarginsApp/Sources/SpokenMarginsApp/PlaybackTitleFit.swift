import SwiftUI
import UIKit

/// #295 (found on the phone): a long title on Now Playing wrapped across five or more lines at
/// the large serif size and pushed the rest of the screen down. The owner's rule (2026-09-30,
/// round-two playback design, section 4):
/// 1. Budget three lines. Try Large (`.largeTitle`), then Medium (`.title`), then Small
///    (`.title2`); use the first size where the whole title fits.
/// 2. If Small still doesn't fit, clip at three lines with "…". Tapping the title opens the
///    item details, which show it in full.
/// 3. The sizes are text styles, so they follow Dynamic Type. At the accessibility sizes, keep
///    Large, allow four lines and clip instead of shrinking.
@MainActor
enum PlaybackTitleFit {
    struct Choice: Equatable {
        var style: Font.TextStyle
        var lineLimit: Int
    }

    static let lineBudget = 3
    static let accessibilityLineBudget = 4
    static let steps: [Font.TextStyle] = [.largeTitle, .title, .title2]

    /// `lineCount` answers how many lines the title takes at a text style when nothing clips it.
    static func choose(
        isAccessibilitySize: Bool,
        lineCount: (Font.TextStyle) -> Int
    ) -> Choice {
        if isAccessibilitySize {
            return Choice(style: .largeTitle, lineLimit: accessibilityLineBudget)
        }
        for style in steps where lineCount(style) <= lineBudget {
            return Choice(style: style, lineLimit: lineBudget)
        }
        return Choice(style: steps[steps.count - 1], lineLimit: lineBudget)
    }

    /// The rule for a title laid out `width` points wide. Before the width is known, Large
    /// clipped at the budget: never more than the budget, even for a frame.
    static func choose(_ title: String, width: CGFloat, dynamicTypeSize: DynamicTypeSize) -> Choice {
        guard width > 0 else {
            return Choice(style: .largeTitle, lineLimit: dynamicTypeSize.isAccessibilitySize ? accessibilityLineBudget : lineBudget)
        }
        let category = contentSizeCategory(dynamicTypeSize)
        return choose(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) { style in
            lineCount(of: title, font: font(for: style, category: category), width: width)
        }
    }

    /// The UIKit twin of `.system(style, design: .serif).weight(.medium)`, for measuring.
    static func font(for style: Font.TextStyle, category: UIContentSizeCategory) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: uiTextStyle(style), compatibleWith: traits)
        let serif = base.withDesign(.serif) ?? base
        let medium = serif.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]])
        return UIFont(descriptor: medium, size: 0)
    }

    /// Lines the text wraps to at this width, laid out with TextKit as SwiftUI's Text does.
    static func lineCount(of text: String, font: UIFont, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 0 }
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in
            lines += 1
        }
        return lines
    }

    static func contentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }

    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

/// The Now Playing title, sized by `PlaybackTitleFit`.
struct PlaybackHeaderTitle: View {
    let title: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    var body: some View {
        let fit = PlaybackTitleFit.choose(title, width: width, dynamicTypeSize: dynamicTypeSize)
        Text(title)
            .font(.system(fit.style, design: .serif).weight(.medium))
            .lineLimit(fit.lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
