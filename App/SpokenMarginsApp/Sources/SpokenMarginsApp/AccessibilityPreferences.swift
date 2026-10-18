import SwiftUI

/// Reads Differentiate Without Color and Increase Contrast in one place (#1922). A view declares
/// `private let preferences = AppAccessibilityPreferences()` and asks it, instead of reading two environment
/// values itself.
struct AppAccessibilityPreferences: DynamicProperty {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast

    /// True when a state shown by colour needs a glyph or label as well.
    var differentiatesWithoutColor: Bool { differentiateWithoutColor }

    /// True when edges and fills should reach their stronger variants.
    var increasesContrast: Bool { contrast == .increased }
}

private struct IncreasedContrastEdge: ViewModifier {
    let preferences = AppAccessibilityPreferences()
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if preferences.increasesContrast {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.border, lineWidth: 1)
            }
        }
    }
}

extension View {
    /// An edge for a fill that is nearly the same colour as its surface (an input or a transcript box). Draws
    /// nothing unless Increase Contrast is on, so the default look is unchanged.
    func increasedContrastEdge(cornerRadius: CGFloat) -> some View {
        modifier(IncreasedContrastEdge(cornerRadius: cornerRadius))
    }
}
