import SessionKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

extension AppColors {
    /// A colour that is `colors` normally and `increased` under Increase Contrast (#1922). The border token uses it
    /// to reach 3:1 on its surface. Lives here, not in Gate1RootView, which may not grow.
    static func contrastAware(_ colors: AppDynamicRGB, increased: AppDynamicRGB) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            let chosen = traits.accessibilityContrast == .high ? increased : colors
            let value = traits.userInterfaceStyle == .dark ? chosen.dark : chosen.light
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        })
        #else
        return Color(red: colors.light.red, green: colors.light.green, blue: colors.light.blue)
        #endif
    }
}
