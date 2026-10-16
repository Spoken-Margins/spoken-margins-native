import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// `Gate1RootView` swaps whole screens in place (Now Playing, the Recording screen, a written Margin, an item)
/// instead of pushing them, so iOS sends VoiceOver no "the screen changed" cue and its focus can stay on an
/// element that is gone. Each of those screens posts it once, when it appears, so VoiceOver lands on the new
/// screen's first element. It does nothing when VoiceOver is off.
private struct ScreenChangeAnnouncement: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            #if canImport(UIKit)
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            #endif
        }
    }
}

extension View {
    /// For a screen the root view shows in place of another one. Not for panes inside a screen.
    func announcesScreenChange() -> some View {
        modifier(ScreenChangeAnnouncement())
    }
}
