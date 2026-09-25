import SwiftUI

/// Desktop counterparts of the iOS app's bone, evergreen, editorial type and surfaces.
enum DesktopPalette {
    static let actionFill = Color(red: 0.08, green: 0.30, blue: 0.21)
    static func bone(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.08, green: 0.10, blue: 0.09) : Color(red: 0.97, green: 0.95, blue: 0.89)
    }

    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.13, green: 0.16, blue: 0.14) : .white
    }

    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.92, green: 0.95, blue: 0.91) : Color(red: 0.09, green: 0.13, blue: 0.11)
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.66, green: 0.72, blue: 0.68) : Color(red: 0.38, green: 0.44, blue: 0.41)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.28, green: 0.34, blue: 0.30) : Color(red: 0.84, green: 0.87, blue: 0.81)
    }

    static func evergreen(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.48, green: 0.84, blue: 0.62) : Color(red: 0.08, green: 0.30, blue: 0.21)
    }
}

struct DesktopPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(DesktopPalette.actionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct DesktopSurface<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopPalette.panel(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(DesktopPalette.border(scheme), lineWidth: 0.75)
            }
    }
}

struct DesktopEyebrow: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(DesktopPalette.evergreen(scheme))
    }
}
